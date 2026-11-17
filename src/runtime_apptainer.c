/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * runtime_apptainer.c - Slurm runtime plugin that runs tasks in Apptainer.
 *
 * The plugin has two parts:
 *
 * - In srun, sbatch and salloc it registers the options and passes their
 *   values on: the image in the container field of the job, step and launch
 *   request, everything else in SLURM_APPTAINER_* variables of the
 *   environment that the tasks get.
 * - In slurmstepd it replaces the exec of each task with
 *   "apptainer exec <image> <command>". slurmstepd calls it as the last step
 *   of the task launch, so the task keeps the TaskProlog results, the
 *   propagated limits and the complete job environment.
 */
#include "config.h"

#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "slurm/slurm.h"
#include "slurm/slurm_errno.h"

#include "src/common/data.h"
#include "src/common/env.h"
#include "src/common/fd.h"
#include "src/common/log.h"
#include "src/common/parse_config.h"
#include "src/common/read_config.h"
#include "src/common/slurm_opt.h"
#include "src/common/xmalloc.h"
#include "src/common/xstring.h"

#include "src/interfaces/runtime.h"

#include "src/slurmd/slurmd/slurmd.h"
#include "src/slurmd/slurmstepd/slurmstepd_job.h"

#include "command.h"

#define CONF_FILE "apptainer.conf"
#define DEFAULT_EXECUTABLE "apptainer"
/* Searched after the PATH of the job when Executable has no directory. */
#define DEFAULT_PATH "/usr/local/bin:/usr/bin:/bin"

/* Required Slurm plugin symbols: */
const char plugin_name[] = "Apptainer runtime plugin";
const char plugin_type[] = "runtime/apptainer";
const uint32_t plugin_version = SLURM_VERSION_NUMBER;

/*
 * The plugin interface. Slurm has no header that declares these functions:
 * it finds them by name when it loads the plugin.
 */
extern int runtime_p_init(const int idx, runtime_context_t context);
extern int runtime_p_fini(void);
extern int runtime_p_setup(slurmd_conf_t *conf, stepd_step_rec_t *step,
			   slurm_addr_t *cli, slurm_msg_t *msg);
extern void runtime_p_cleanup(slurmd_conf_t *conf, stepd_step_rec_t *step);
extern void runtime_p_task_init(slurmd_conf_t *conf, stepd_step_rec_t *step,
				stepd_step_task_info_t *task);
extern int runtime_p_run(slurmd_conf_t *conf, stepd_step_rec_t *step,
			 stepd_step_task_info_t *task);
extern int runtime_p_cli_apply_job_desc(const uint32_t het_job_inx,
					runtime_context_t context,
					job_desc_msg_t *job_desc);
extern int runtime_p_cli_apply_step_req(const uint32_t het_job_inx,
					runtime_context_t context,
					step_create_req_msg_t *step_req);
extern void runtime_p_cli_reset_args(const uint32_t het_job_inx);
extern int runtime_p_cli_apply_launch_params(const uint32_t het_job_inx,
					     runtime_context_t context,
					     slurm_step_launch_params_t
						     *launch_params);
extern int runtime_p_cli_apply_env(const uint32_t het_job_inx,
				   const uint32_t het_job_offset,
				   runtime_context_t context, bool child,
				   char ***envp);
extern int runtime_p_cli_apply_interactive_step(const uint32_t het_job_inx,
						runtime_context_t context,
						char **command);

typedef enum {
	ARG_CONTAINER = 0,
	ARG_BIND,
	ARG_ARGS,
	ARG_NO_DEFAULT_BINDS,
	ARG_CNT,
} arg_id_t;

static bool _on_arg(const runtime_arg_t *arg, const uint32_t het_job_inx,
		    data_t *value, bool set_by_cli, bool set_by_env,
		    bool set_by_data, bool early_pass);

/*
 * The options of the plugin, indexed by arg_id_t.
 *
 * --container is the option of runtime/oci too. Slurm lets several runtimes
 * register one option name and gives the value to the runtime of the job.
 */
static const runtime_arg_t args[ARG_CNT] = {
	[ARG_CONTAINER] = {
		.argument = "container",
		.environment = {
			.salloc = "SALLOC_CONTAINER",
			.sbatch = "SBATCH_CONTAINER",
			.slurm = "SLURM_CONTAINER",
			.srun = "SRUN_CONTAINER",
		},
		.field = "container",
		.field_desc = "Container image, or \"none\" for no container",
		.field_type = DATA_PARSER_STRING,
		.help_value = "image",
		.on_arg = _on_arg,
	},
	[ARG_BIND] = {
		.argument = "apptainer-bind",
		.environment = {
			.salloc = "SALLOC_APPTAINER_BIND",
			.sbatch = "SBATCH_APPTAINER_BIND",
			.slurm = "SLURM_APPTAINER_BIND",
			.srun = "SRUN_APPTAINER_BIND",
		},
		.field = "apptainer_bind",
		.field_desc = "Bind paths to add to the container",
		.field_type = DATA_PARSER_STRING,
		.help_value = "src[:dest[:opts]],...",
		.on_arg = _on_arg,
	},
	[ARG_ARGS] = {
		.argument = "apptainer-args",
		.environment = {
			.salloc = "SALLOC_APPTAINER_ARGS",
			.sbatch = "SBATCH_APPTAINER_ARGS",
			.slurm = "SLURM_APPTAINER_ARGS",
			.srun = "SRUN_APPTAINER_ARGS",
		},
		.field = "apptainer_args",
		.field_desc = "Arguments to add to \"apptainer exec\"",
		.field_type = DATA_PARSER_STRING,
		.help_value = "args",
		.on_arg = _on_arg,
	},
	[ARG_NO_DEFAULT_BINDS] = {
		.argument = "apptainer-no-default-binds",
		.environment = {
			.salloc = "SALLOC_APPTAINER_NO_DEFAULT_BINDS",
			.sbatch = "SBATCH_APPTAINER_NO_DEFAULT_BINDS",
			.slurm = "SLURM_APPTAINER_NO_DEFAULT_BINDS",
			.srun = "SRUN_APPTAINER_NO_DEFAULT_BINDS",
		},
		.field = "apptainer_no_default_binds",
		.field_desc = "Leave out the bind paths of the site",
		.field_type = DATA_PARSER_STRING,
		.help_value = "yes|no",
		.on_arg = _on_arg,
	},
};

/* Option values of one heterogeneous job component. */
typedef struct {
	char *value[ARG_CNT]; /* NULL when the option is not set */
	bool set_by_cli[ARG_CNT]; /* false when the value is from a variable */
} component_t;

#define COMPONENT_CHUNK 8
static component_t *components = NULL;
static uint32_t component_cnt = 0;

/* Contents of apptainer.conf. Loaded in slurmstepd only. */
typedef struct {
	char *executable; /* Executable */
	char *default_image; /* DefaultImage */
	char *bind; /* Bind */
	char *global_args; /* GlobalArgs */
	char *exec_args; /* ExecArgs */
	bool allow_user_args; /* AllowUserArgs */
} apptainer_conf_t;

static apptainer_conf_t apptainer_conf = {
	.allow_user_args = true,
};

/* Command of the task as the user gave it. Set in the task process only. */
static char *task_command = NULL;

static s_p_options_t conf_options[] = {
	{ .key = "AllowUserArgs", .type = S_P_BOOLEAN },
	{ .key = "Bind", .type = S_P_STRING },
	{ .key = "DefaultImage", .type = S_P_STRING },
	{ .key = "ExecArgs", .type = S_P_STRING },
	{ .key = "Executable", .type = S_P_STRING },
	{ .key = "GlobalArgs", .type = S_P_STRING },
	{ .key = NULL },
};

/* RET the stored values of a component, or NULL when it has none */
static const component_t *_find_component(const uint32_t het_job_inx)
{
	if ((het_job_inx == NO_VAL) || (het_job_inx >= component_cnt))
		return NULL;

	return &components[het_job_inx];
}

/* RET the variable that a command reads an option from, or NULL */
static const char *_input_env_name(const runtime_arg_t *arg,
				   runtime_context_t context)
{
	switch (context) {
	case RUNTIME_CTXT_SALLOC:
		return arg->environment.salloc;
	case RUNTIME_CTXT_SBATCH:
		return arg->environment.sbatch;
	case RUNTIME_CTXT_SRUN:
		return arg->environment.srun;
	default:
		return NULL;
	}
}

/*
 * RET the value of an option for a component, or NULL when it is not set.
 *
 * The value comes from, in this order:
 *
 * 1. The option, or its variable, that Slurm gave to _on_arg().
 * 2. The variable of the command (e.g. SBATCH_CONTAINER). Slurm reads the
 *    variables before it reads --runtime from the command line, and gives
 *    them to the runtime that it knows then. Thus the plugin does not get
 *    them when only the command line selects it.
 * 3. In srun, the SLURM_* variable that sbatch and salloc export, like srun
 *    takes SLURM_NTASKS. Thus the steps of a job use the options of the
 *    job.
 */
static const char *_get_value(const uint32_t het_job_inx,
			      runtime_context_t context, const arg_id_t id)
{
	const component_t *component = _find_component(het_job_inx);
	const char *name = _input_env_name(&args[id], context);
	const char *value = NULL;

	if (component && component->value[id])
		return component->value[id];

	if (name && (value = getenv(name)))
		return value;

	if (context == RUNTIME_CTXT_SRUN)
		return getenv(args[id].environment.slurm);

	return NULL;
}

/* RET the image of a component, "none" for no container, or NULL */
static const char *_get_image(const uint32_t het_job_inx,
			      runtime_context_t context)
{
	const char *image = _get_value(het_job_inx, context, ARG_CONTAINER);

	if (image && command_image_is_none(image))
		return COMMAND_IMAGE_NONE;

	return image;
}

static bool _on_arg(const runtime_arg_t *arg, const uint32_t het_job_inx,
		    data_t *value, bool set_by_cli, bool set_by_env,
		    bool set_by_data, bool early_pass)
{
	const arg_id_t id = (arg - args);
	component_t *component = NULL;
	char *str = NULL;

	xassert(id < ARG_CNT);
	xassert(het_job_inx != NO_VAL);

	if (value && data_get_string_converted(value, &str)) {
		error("--%s requires a string value", arg->argument);
		return false;
	}

	switch (id) {
	case ARG_CONTAINER:
		if (!str) {
			error("--%s requires a value: use --%s=%s", arg->argument,
			      arg->argument, arg->help_value);
			return false;
		}
		/* An empty value asks for no container, like "none". */
		if (command_image_is_none(str)) {
			xfree(str);
			str = xstrdup(COMMAND_IMAGE_NONE);
		}
		break;
	case ARG_NO_DEFAULT_BINDS:
	{
		bool flag = true;

		/* The option without a value means yes. */
		if (str && str[0] && !command_parse_bool(str, &flag)) {
			error("--%s requires yes or no, not: %s", arg->argument,
			      str);
			xfree(str);
			return false;
		}
		xfree(str);
		str = xstrdup(flag ? "yes" : "no");
		break;
	}
	case ARG_BIND:
	case ARG_ARGS:
		/* An empty value removes a value that the job gave. */
		if (!str)
			str = xstrdup("");
		break;
	default:
		xfree(str);
		return false;
	}

	if (het_job_inx >= component_cnt) {
		const uint32_t cnt = (((het_job_inx / COMPONENT_CHUNK) + 1) *
				      COMPONENT_CHUNK);

		xrecalloc(components, cnt, sizeof(*components));
		component_cnt = cnt;
	}

	component = &components[het_job_inx];

	/*
	 * A list option that is given again on the command line adds to the
	 * list. The command line replaces a value from the environment.
	 */
	if (((id == ARG_BIND) || (id == ARG_ARGS)) && set_by_cli &&
	    component->set_by_cli[id] && component->value[id] &&
	    component->value[id][0] && str[0]) {
		xstrfmtcat(component->value[id], "%s%s",
			   ((id == ARG_BIND) ? "," : " "), str);
		xfree(str);
	} else {
		xfree(component->value[id]);
		component->value[id] = str;
	}

	component->set_by_cli[id] = set_by_cli;

	return true;
}

extern int runtime_p_init(const int idx, runtime_context_t context)
{
	for (int i = 0; i < ARG_CNT; i++)
		runtime_register_arg(idx, &args[i]);

	return SLURM_SUCCESS;
}

static void _free_conf(void)
{
	xfree(apptainer_conf.executable);
	xfree(apptainer_conf.default_image);
	xfree(apptainer_conf.bind);
	xfree(apptainer_conf.global_args);
	xfree(apptainer_conf.exec_args);
	apptainer_conf.allow_user_args = true;
}

extern int runtime_p_fini(void)
{
	for (uint32_t i = 0; i < component_cnt; i++)
		runtime_p_cli_reset_args(i);

	xfree(components);
	component_cnt = 0;
	_free_conf();

	return SLURM_SUCCESS;
}

extern void runtime_p_cli_reset_args(const uint32_t het_job_inx)
{
	if (het_job_inx >= component_cnt)
		return;

	for (int i = 0; i < ARG_CNT; i++) {
		xfree(components[het_job_inx].value[i]);
		components[het_job_inx].set_by_cli[i] = false;
	}
}

extern int runtime_p_cli_apply_job_desc(const uint32_t het_job_inx,
					runtime_context_t context,
					job_desc_msg_t *job_desc)
{
	const char *image = _get_image(het_job_inx, context);

	if (!image)
		return SLURM_SUCCESS;

	xfree(job_desc->container);
	job_desc->container = xstrdup(image);

	return SLURM_SUCCESS;
}

extern int runtime_p_cli_apply_step_req(const uint32_t het_job_inx,
					runtime_context_t context,
					step_create_req_msg_t *step_req)
{
	const char *image = _get_image(het_job_inx, context);

	if (!image)
		return SLURM_SUCCESS;

	xfree(step_req->container);
	step_req->container = xstrdup(image);

	return SLURM_SUCCESS;
}

extern int runtime_p_cli_apply_launch_params(const uint32_t het_job_inx,
					     runtime_context_t context,
					     slurm_step_launch_params_t
						     *launch_params)
{
	const char *image = _get_image(het_job_inx, context);

	/* The caller does not free the pointer, see runtime.h. */
	if (image)
		launch_params->container = (char *) image;

	return SLURM_SUCCESS;
}

/*
 * RET the variable that an option is exported as, or NULL: the variable
 *	that context reads itself, or with child the variable for what
 *	context starts
 */
static const char *_output_env_name(const runtime_arg_t *arg,
				    runtime_context_t context, bool child)
{
	if (!child)
		return _input_env_name(arg, context);

	switch (context) {
	case RUNTIME_CTXT_SALLOC:
	case RUNTIME_CTXT_SBATCH:
	case RUNTIME_CTXT_SCRONTAB:
	case RUNTIME_CTXT_SCRUN:
	case RUNTIME_CTXT_SRUN:
		return arg->environment.slurm;
	default:
		return NULL;
	}
}

extern int runtime_p_cli_apply_env(const uint32_t het_job_inx,
				   const uint32_t het_job_offset,
				   runtime_context_t context, bool child,
				   char ***envp)
{
	/* setenvf() writes to the process environment if the array is NULL */
	if (envp && !*envp)
		*envp = env_array_create();

	/*
	 * srun reads its runtime from SRUN_RUNTIME only, not from the
	 * SLURM_RUNTIME of the job. Without this variable, the steps of a job
	 * get DefRuntimePlugin, which does not know the options of this
	 * plugin. An explicit --runtime of srun still wins.
	 */
	if (child && (het_job_offset == NO_VAL))
		setenvf(envp, "SRUN_RUNTIME", "%s", (plugin_type + 8));

	for (int i = 0; i < ARG_CNT; i++) {
		const char *name = _output_env_name(&args[i], context, child);
		const char *value = ((i == ARG_CONTAINER) ?
					     _get_image(het_job_inx, context) :
					     _get_value(het_job_inx, context, i));
		char *het_name = NULL;

		if (!name || !value)
			continue;

		/* The components of a heterogeneous job share an environment */
		if (het_job_offset != NO_VAL)
			name = het_name = xstrdup_printf("%s_HET_GROUP_%u", name,
							 het_job_offset);

		setenvf(envp, name, "%s", value);
		xfree(het_name);
	}

	return SLURM_SUCCESS;
}

extern int runtime_p_cli_apply_interactive_step(const uint32_t het_job_inx,
						runtime_context_t context,
						char **command)
{
	/*
	 * salloc exports the SLURM_* variables to its command with
	 * runtime_p_cli_apply_env(). The srun of the interactive step takes
	 * the values from them, see _get_value().
	 */
	return SLURM_SUCCESS;
}

/*
 * Find apptainer.conf.
 * RET path to xfree(), or NULL when the node has no such file
 */
static char *_find_conf(void)
{
	struct stat st;
	char *path = get_extra_conf_path(CONF_FILE);
	char *dir = NULL, *slash = NULL;

	if (path && !stat(path, &st))
		return path;

	xfree(path);

	/*
	 * A node in configless mode reads its configuration from a cache
	 * that holds only the files that slurmctld sends. Look next to the
	 * default slurm.conf also.
	 */
	dir = xstrdup(default_slurm_config_file);
	if ((slash = strrchr(dir, '/'))) {
		*slash = '\0';
		path = xstrdup_printf("%s/%s", dir, CONF_FILE);
	}
	xfree(dir);

	if (path && !stat(path, &st))
		return path;

	xfree(path);
	return NULL;
}

static int _load_conf(void)
{
	s_p_hashtbl_t *tbl = NULL;
	char *path = _find_conf();

	_free_conf();

	if (!path) {
		debug("%s: no %s, using the defaults", plugin_type, CONF_FILE);
		return SLURM_SUCCESS;
	}

	debug("%s: reading %s", plugin_type, path);

	tbl = s_p_hashtbl_create(conf_options);
	if (s_p_parse_file(tbl, NULL, path, 0, NULL) == SLURM_ERROR) {
		error("%s: cannot parse %s", plugin_type, path);
		s_p_hashtbl_destroy(tbl);
		xfree(path);
		return SLURM_ERROR;
	}

	(void) s_p_get_boolean(&apptainer_conf.allow_user_args, "AllowUserArgs",
			       tbl);
	(void) s_p_get_string(&apptainer_conf.bind, "Bind", tbl);
	(void) s_p_get_string(&apptainer_conf.default_image, "DefaultImage",
			      tbl);
	(void) s_p_get_string(&apptainer_conf.exec_args, "ExecArgs", tbl);
	(void) s_p_get_string(&apptainer_conf.executable, "Executable", tbl);
	(void) s_p_get_string(&apptainer_conf.global_args, "GlobalArgs", tbl);

	s_p_hashtbl_destroy(tbl);
	xfree(path);

	return SLURM_SUCCESS;
}

/*
 * Set the container record of the step to the image that the step uses.
 *
 * slurmstepd makes the record for a step that names a container. Other
 * plugins read it: mpi/pmix puts the files that its clients open into
 * spool_dir of a step with a record. Thus a step that runs on the node has
 * no record, and a step in a container has a record with a spool_dir.
 */
static void _set_container(stepd_step_rec_t *step)
{
	step_container_t *c = step->container;

	if (!c && !command_image_is_none(apptainer_conf.default_image)) {
		c = xmalloc(sizeof(*c));
		c->magic = STEP_CONTAINER_MAGIC;
		c->bundle = xstrdup(apptainer_conf.default_image);
		step->container = c;
	} else if (c && command_image_is_none(c->bundle)) {
		xfree(c->bundle);
		xfree(step->container);
	}
}

/*
 * Make the directory of the step in the spool directory of slurmd. It holds
 * the files that plugins of Slurm share with the tasks. The user owns it,
 * and the tasks see it at the same path in the container.
 */
static int _make_spool_dir(slurmd_conf_t *conf, stepd_step_rec_t *step)
{
	step_container_t *c = step->container;
	char step_id[32];
	struct stat st;
	int rc;

	log_build_step_id_str(&step->step_id, step_id, sizeof(step_id),
			      (STEP_ID_FLAG_NO_JOB | STEP_ID_FLAG_NO_PREFIX));

	xfree(c->spool_dir);
	xfree(c->mount_spool_dir);
	c->spool_dir = xstrdup_printf("%s/apptainer.%u.%s", conf->spooldir,
				      step->step_id.job_id, step_id);
	c->mount_spool_dir = xstrdup(c->spool_dir);

	if (mkdir(c->spool_dir, S_IRWXU) && (errno != EEXIST)) {
		rc = errno;
		error("%s: mkdir(%s): %m", plugin_type, c->spool_dir);
		return rc;
	}

	/*
	 * Only root makes entries in the spool directory of slurmd, thus a
	 * directory with this name is one of this plugin. Do not follow a
	 * link.
	 */
	if (lstat(c->spool_dir, &st) || !S_ISDIR(st.st_mode)) {
		error("%s: %s is not a directory", plugin_type, c->spool_dir);
		return ENOTDIR;
	}

	if (chown(c->spool_dir, step->uid, step->gid)) {
		rc = errno;
		error("%s: chown(%s): %m", plugin_type, c->spool_dir);
		return rc;
	}

	return SLURM_SUCCESS;
}

/* RET true if a directory has an entry */
static bool _dir_has_entry(const char *path)
{
	DIR *dir = opendir(path);
	struct dirent *entry = NULL;
	bool found = false;

	if (!dir)
		return false;

	while (!found && (entry = readdir(dir)))
		found = (strcmp(entry->d_name, ".") &&
			 strcmp(entry->d_name, ".."));

	closedir(dir);
	return found;
}

extern int runtime_p_setup(slurmd_conf_t *conf, stepd_step_rec_t *step,
			   slurm_addr_t *cli, slurm_msg_t *msg)
{
	int rc;

	if ((rc = _load_conf()))
		return rc;

	_set_container(step);

	if (!step->container)
		return SLURM_SUCCESS;

	return _make_spool_dir(conf, step);
}

extern void runtime_p_cleanup(slurmd_conf_t *conf, stepd_step_rec_t *step)
{
	if (!step->container || !step->container->spool_dir)
		return;

	/* The container ends with its task. Only the directory stays. */
	(void) rmdir_recursive(step->container->spool_dir, true);
}

extern void runtime_p_task_init(slurmd_conf_t *conf, stepd_step_rec_t *step,
				stepd_step_task_info_t *task)
{
	/*
	 * slurmstepd calls this function in the process of the task, before
	 * it searches the command in the PATH of the job on the node. Keep
	 * the command as the user gave it: see runtime_p_run().
	 */
	xfree(task_command);
	if (task->argv && task->argv[0])
		task_command = xstrdup(task->argv[0]);
}

/* RET path of the Apptainer program to free(), or NULL */
static char *_find_executable(char **env)
{
	const char *executable = (apptainer_conf.executable ?
					  apptainer_conf.executable :
					  DEFAULT_EXECUTABLE);
	char *path = command_find_program(executable, getenvp(env, "PATH"));

	if (!path)
		path = command_find_program(executable, DEFAULT_PATH);

	return path;
}

extern int runtime_p_run(slurmd_conf_t *conf, stepd_step_rec_t *step,
			 stepd_step_task_info_t *task)
{
	const step_container_t *c = step->container;
	const char *no_default_binds = NULL;
	char *executable = NULL, *errmsg = NULL, *line = NULL;
	char **argv = NULL;
	command_t cmd = { 0 };
	bool flag = false;
	int rc;

	/* No container, see _set_container(): slurmstepd execs the task. */
	if (!c)
		return ESLURM_NOT_SUPPORTED;

	cmd.image = c->bundle;
	cmd.task_argv = task->argv;
	cmd.global_args = apptainer_conf.global_args;
	cmd.exec_args = apptainer_conf.exec_args;
	cmd.default_binds = apptainer_conf.bind;
	cmd.user_binds = getenvp(step->env, args[ARG_BIND].environment.slurm);
	cmd.user_args = getenvp(step->env, args[ARG_ARGS].environment.slurm);

	if (cmd.user_args && cmd.user_args[0] &&
	    !apptainer_conf.allow_user_args) {
		error("%s: --%s is not permitted on this cluster", plugin_type,
		      args[ARG_ARGS].argument);
		return EPERM;
	}

	no_default_binds =
		getenvp(step->env,
			args[ARG_NO_DEFAULT_BINDS].environment.slurm);
	if (no_default_binds && command_parse_bool(no_default_binds, &flag))
		cmd.no_default_binds = flag;

	/* The batch script is in the spool directory of slurmd. */
	if (step->batch)
		cmd.script = task->argv[0];

	/*
	 * A plugin of Slurm put files for the tasks into the directory of the
	 * step, for example the PMIx server its socket.
	 */
	if (c->spool_dir && _dir_has_entry(c->spool_dir))
		cmd.spool_dir = c->spool_dir;

	/*
	 * slurmstepd replaced a command without a directory with the path of
	 * the program on the node. The image can have the program in a
	 * different directory, or only the image has it. Give the name to
	 * Apptainer, which searches it in the PATH of the container.
	 */
	if (task_command && !strchr(task_command, '/'))
		cmd.program = task_command;

	if (!(executable = _find_executable(step->env))) {
		error("%s: cannot find the program %s", plugin_type,
		      (apptainer_conf.executable ? apptainer_conf.executable :
						   DEFAULT_EXECUTABLE));
		return ENOENT;
	}
	cmd.executable = executable;

	if (!(argv = command_build(&cmd, &errmsg))) {
		error("%s: cannot build the command: %s", plugin_type,
		      (errmsg ? errmsg : "unknown error"));
		free(errmsg);
		free(executable);
		return EINVAL;
	}

	line = command_join(argv);
	debug("%s: %s", plugin_type, (line ? line : executable));
	free(line);

	execve(executable, argv, step->env);
	rc = errno;

	error("%s: execve(%s): %m", plugin_type, executable);
	command_free(argv);
	free(executable);

	return rc;
}
