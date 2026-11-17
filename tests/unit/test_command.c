/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * test_command.c - unit tests of the command line builder.
 */
#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "command.h"

static int checks = 0;
static int failures = 0;

#define CHECK(cond) \
	do { \
		checks++; \
		if (!(cond)) { \
			failures++; \
			fprintf(stderr, "%s:%d: check failed: %s\n", \
				__FILE__, __LINE__, #cond); \
		} \
	} while (0)

/* Compare a vector with the words of a '|'-separated string. */
static void _check_vector(const char *file, int line, char **argv,
			  const char *expected)
{
	char *joined = NULL;
	size_t len = 0;
	FILE *out = open_memstream(&joined, &len);

	for (char **arg = argv; arg && *arg; arg++)
		fprintf(out, "%s%s", ((arg == argv) ? "" : "|"), *arg);
	fclose(out);

	checks++;
	if (!argv || strcmp(joined, expected)) {
		failures++;
		fprintf(stderr, "%s:%d: vector differs\n  expected: %s\n  got:      %s\n",
			file, line, expected, (argv ? joined : "(null)"));
	}

	free(joined);
}

#define CHECK_VECTOR(argv, expected) \
	_check_vector(__FILE__, __LINE__, argv, expected)

static void _check_split(const char *file, int line, const char *str,
			 const char *expected)
{
	char *errmsg = NULL;
	char **words = command_split_words(str, &errmsg);

	_check_vector(file, line, words, expected);
	checks++;
	if (errmsg) {
		failures++;
		fprintf(stderr, "%s:%d: unexpected error: %s\n", file, line,
			errmsg);
	}

	free(errmsg);
	command_free(words);
}

#define CHECK_SPLIT(str, expected) \
	_check_split(__FILE__, __LINE__, str, expected)

static void _check_split_error(const char *file, int line, const char *str)
{
	char *errmsg = NULL;
	char **words = command_split_words(str, &errmsg);

	checks++;
	if (words || !errmsg) {
		failures++;
		fprintf(stderr, "%s:%d: expected an error for: %s\n", file,
			line, str);
	}

	free(errmsg);
	command_free(words);
}

#define CHECK_SPLIT_ERROR(str) _check_split_error(__FILE__, __LINE__, str)

static void test_split_words(void)
{
	CHECK_SPLIT(NULL, "");
	CHECK_SPLIT("", "");
	CHECK_SPLIT("  \t\n ", "");
	CHECK_SPLIT("--userns", "--userns");
	CHECK_SPLIT("  --nv   --no-home ", "--nv|--no-home");
	CHECK_SPLIT("--home '/net work/a'", "--home|/net work/a");
	CHECK_SPLIT("--env \"A=b c\"", "--env|A=b c");
	CHECK_SPLIT("a\\ b c", "a b|c");
	CHECK_SPLIT("\"a \\\" b\"", "a \" b");
	CHECK_SPLIT("\"a \\n b\"", "a \\n b");
	CHECK_SPLIT("'a \\ b'", "a \\ b");
	CHECK_SPLIT("pre'fix 'd\"one \"x", "prefix done x");
	CHECK_SPLIT("''", "");
	CHECK_SPLIT("a '' b", "a||b");
	CHECK_SPLIT("$HOME `id` *", "$HOME|`id`|*");

	CHECK_SPLIT_ERROR("'open");
	CHECK_SPLIT_ERROR("\"open");
	CHECK_SPLIT_ERROR("end\\");
}

static void test_build(void)
{
	char *task[] = { "/bin/echo", "a b", NULL };
	char *errmsg = NULL;
	char **argv = NULL;
	command_t cmd = {
		.image = "/img/c.sif",
		.task_argv = task,
	};

	/* Minimal command. */
	argv = command_build(&cmd, &errmsg);
	CHECK_VECTOR(argv, "apptainer|exec|/img/c.sif|/bin/echo|a b");
	CHECK(!errmsg);
	command_free(argv);

	/* Every input, in the documented order. */
	cmd = (command_t) {
		.executable = "/usr/bin/apptainer",
		.global_args = "--silent",
		.exec_args = "--userns --home '/net work'",
		.default_binds = "/etc/slurm,/var/spool/slurmd",
		.user_binds = "/srv:/mnt:ro,,/scratch,",
		.user_args = "--nv",
		.script = "/var/spool/slurmd/job00042/slurm_script",
		.spool_dir = "/var/spool/slurmd/apptainer.42.0",
		.image = "/img/c.sif",
		.task_argv = task,
	};
	argv = command_build(&cmd, &errmsg);
	CHECK_VECTOR(argv, "/usr/bin/apptainer|--silent|exec|--userns|--home|"
			   "/net work|--bind|/etc/slurm|--bind|"
			   "/var/spool/slurmd|--bind|"
			   "/var/spool/slurmd/job00042/slurm_script:"
			   "/var/spool/slurmd/job00042/slurm_script:ro|"
			   "--bind|/var/spool/slurmd/apptainer.42.0|"
			   "--bind|/srv:/mnt:ro|--bind|/scratch|--nv|"
			   "/img/c.sif|/bin/echo|a b");
	CHECK(!errmsg);
	command_free(argv);

	/* The program name replaces the first word of the task command. */
	cmd = (command_t) {
		.image = "/img/c.sif",
		.task_argv = task,
		.program = "echo",
	};
	argv = command_build(&cmd, &errmsg);
	CHECK_VECTOR(argv, "apptainer|exec|/img/c.sif|echo|a b");
	command_free(argv);

	cmd = (command_t) {
		.executable = "/usr/bin/apptainer",
		.default_binds = "/etc/slurm,/var/spool/slurmd",
		.user_binds = "/srv:/mnt:ro,,/scratch,",
		.image = "/img/c.sif",
		.task_argv = task,
	};

	/* The job can leave out the site binds, but not its own. */
	cmd.no_default_binds = true;
	argv = command_build(&cmd, &errmsg);
	CHECK_VECTOR(argv, "/usr/bin/apptainer|exec|--bind|/srv:/mnt:ro|--bind|"
			   "/scratch|/img/c.sif|/bin/echo|a b");
	command_free(argv);
}

static void test_build_errors(void)
{
	char *task[] = { "true", NULL };
	char *empty[] = { NULL };
	char *errmsg = NULL;
	command_t cmd = { .image = "/img/c.sif", .task_argv = task };

	cmd.image = NULL;
	CHECK(!command_build(&cmd, &errmsg));
	CHECK(errmsg && strstr(errmsg, "image"));
	free(errmsg);

	cmd.image = "none";
	CHECK(!command_build(&cmd, &errmsg));
	free(errmsg);

	cmd.image = "/img/c.sif";
	cmd.task_argv = empty;
	CHECK(!command_build(&cmd, &errmsg));
	CHECK(errmsg && strstr(errmsg, "command"));
	free(errmsg);

	cmd.task_argv = task;
	cmd.user_args = "--home 'open";
	CHECK(!command_build(&cmd, &errmsg));
	CHECK(errmsg && strstr(errmsg, "user arguments"));
	free(errmsg);

	cmd.user_args = NULL;
	cmd.exec_args = "\"open";
	CHECK(!command_build(&cmd, &errmsg));
	CHECK(errmsg && strstr(errmsg, "exec arguments"));
	free(errmsg);

	/* A NULL errmsg is allowed. */
	CHECK(!command_build(&cmd, NULL));
}

static void test_image_is_none(void)
{
	CHECK(command_image_is_none(NULL));
	CHECK(command_image_is_none(""));
	CHECK(command_image_is_none("none"));
	CHECK(command_image_is_none("NONE"));
	CHECK(!command_image_is_none("/img/none"));
	CHECK(!command_image_is_none("docker://alpine"));
}

static void test_parse_bool(void)
{
	bool value = false;

	CHECK(command_parse_bool("yes", &value) && value);
	CHECK(command_parse_bool("TRUE", &value) && value);
	CHECK(command_parse_bool("on", &value) && value);
	CHECK(command_parse_bool("1", &value) && value);
	CHECK(command_parse_bool("no", &value) && !value);
	CHECK(command_parse_bool("False", &value) && !value);
	CHECK(command_parse_bool("off", &value) && !value);
	CHECK(command_parse_bool("0", &value) && !value);
	CHECK(!command_parse_bool("", &value));
	CHECK(!command_parse_bool("maybe", &value));
	CHECK(!command_parse_bool(NULL, &value));
}

static void test_find_program(void)
{
	char dir[] = "/tmp/test_command.XXXXXX";
	char *program = NULL, *plain = NULL, *path = NULL, *found = NULL;
	FILE *file = NULL;

	CHECK(mkdtemp(dir));
	CHECK(asprintf(&program, "%s/apptainer", dir) > 0);
	CHECK(asprintf(&plain, "%s/data", dir) > 0);
	CHECK(asprintf(&path, "/nonexistent::%s:/usr/bin", dir) > 0);

	CHECK((file = fopen(program, "w")));
	fclose(file);
	CHECK(!chmod(program, 0755));
	CHECK((file = fopen(plain, "w")));
	fclose(file);
	CHECK(!chmod(plain, 0644));

	found = command_find_program("apptainer", path);
	CHECK(found && !strcmp(found, program));
	free(found);

	/* A file that is not executable is not a program. */
	CHECK(!command_find_program("data", path));

	/* A directory is not a program. */
	CHECK(!command_find_program("bin", "/usr"));

	CHECK(!command_find_program("apptainer", "/nonexistent"));
	CHECK(!command_find_program("apptainer", NULL));
	CHECK(!command_find_program("", path));
	CHECK(!command_find_program(NULL, path));

	/* A name with a slash is not searched. */
	found = command_find_program("./rel/apptainer", path);
	CHECK(found && !strcmp(found, "./rel/apptainer"));
	free(found);

	unlink(program);
	unlink(plain);
	rmdir(dir);
	free(program);
	free(plain);
	free(path);
}

static void test_join(void)
{
	char *argv[] = { "apptainer", "exec", "--bind", "/a:/b:ro", "a b",
			 "it's", "", "$HOME", NULL };
	char *empty[] = { NULL };
	char *line = command_join(argv);

	CHECK(line && !strcmp(line, "apptainer exec --bind /a:/b:ro 'a b' "
				    "'it'\\''s' '' '$HOME'"));
	free(line);

	line = command_join(empty);
	CHECK(line && !line[0]);
	free(line);

	line = command_join(NULL);
	CHECK(line && !line[0]);
	free(line);
}

int main(void)
{
	test_split_words();
	test_build();
	test_build_errors();
	test_image_is_none();
	test_parse_bool();
	test_find_program();
	test_join();

	printf("%d checks, %d failures\n", checks, failures);
	return (failures ? EXIT_FAILURE : EXIT_SUCCESS);
}
