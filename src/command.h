/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * command.h - build the Apptainer command line of a task.
 *
 * This module has no Slurm dependency. All memory comes from malloc(), so
 * that the unit tests can link it without Slurm.
 */
#ifndef RUNTIME_APPTAINER_COMMAND_H
#define RUNTIME_APPTAINER_COMMAND_H

#include <stdbool.h>

/* Image name that asks for no container. */
#define COMMAND_IMAGE_NONE "none"

/* Inputs of one "apptainer exec" call. Only image and task_argv are required. */
typedef struct {
	const char *executable; /* Apptainer program, argv[0] of the result */
	const char *global_args; /* site arguments before "exec" */
	const char *exec_args; /* site arguments after "exec" */
	const char *default_binds; /* site bind specs, comma-separated */
	const char *user_binds; /* job bind specs, comma-separated */
	const char *user_args; /* job arguments after "exec" */
	const char *script; /* batch script to bind read-only, or NULL */
	const char *spool_dir; /* directory of the step to bind, or NULL */
	const char *image; /* container image */
	char *const *task_argv; /* NULL-terminated command of the task */
	const char *program; /* replaces task_argv[0] if not NULL */
	bool no_default_binds; /* true to leave out default_binds */
} command_t;

/*
 * Build the argument vector:
 *
 *   executable [global_args] exec [exec_args] [--bind spec]... [user_args]
 *              image task_argv...
 *
 * The bind specs are those of the site, the batch script, the directory of
 * the step and the job, in this sequence.
 *
 * RET NULL-terminated vector to free with command_free(), or NULL on error
 *	with *errmsg set to a message to free().
 */
extern char **command_build(const command_t *cmd, char **errmsg);

extern void command_free(char **argv);

/*
 * Split a string into words like a POSIX shell, without expansions.
 * Whitespace separates words. Single quotes keep every character. Double
 * quotes keep every character except that a backslash escapes '"' and '\'.
 * Outside quotes, a backslash escapes the next character.
 *
 * RET NULL-terminated vector to free with command_free() (empty for a NULL or
 *	blank string), or NULL on error with *errmsg set to a message to free().
 */
extern char **command_split_words(const char *str, char **errmsg);

/*
 * Find an executable file.
 * IN program - program name. A name with a '/' is returned as it is.
 * IN path - colon-separated directories to search, or NULL
 * RET path to free(), or NULL when no directory holds the program
 */
extern char *command_find_program(const char *program, const char *path);

/* RET true when the image name asks for no container (empty or "none"). */
extern bool command_image_is_none(const char *image);

/*
 * Parse a boolean word.
 * IN str - yes/no, true/false, on/off, 1/0 in any case
 * OUT value - parsed value
 * RET false when str is not a boolean word
 */
extern bool command_parse_bool(const char *str, bool *value);

/*
 * Join the words of a vector with spaces for a log message. Words with
 * characters that a shell treats specially are put in single quotes.
 * RET string to free()
 */
extern char *command_join(char *const *argv);

#endif
