/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * command.c - build the Apptainer command line of a task.
 */
#define _GNU_SOURCE

#include "command.h"

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

/* Growing NULL-terminated vector of strings. */
typedef struct {
	char **items;
	size_t count;
	size_t size;
} vector_t;

/* Growing NUL-terminated string. */
typedef struct {
	char *data;
	size_t len;
	size_t size;
} buffer_t;

static bool _vector_push(vector_t *vec, char *item)
{
	/* Keep one free slot for the terminating NULL. */
	if ((vec->count + 2) > vec->size) {
		size_t size = (vec->size ? (vec->size * 2) : 16);
		char **items = realloc(vec->items, (size * sizeof(*items)));

		if (!items)
			return false;

		vec->items = items;
		vec->size = size;
	}

	vec->items[vec->count++] = item;
	vec->items[vec->count] = NULL;
	return true;
}

static bool _vector_push_copy(vector_t *vec, const char *str)
{
	char *copy = strdup(str);

	if (copy && _vector_push(vec, copy))
		return true;

	free(copy);
	return false;
}

/* RET the vector, never NULL for an empty one, or NULL without memory */
static char **_vector_finish(vector_t *vec)
{
	if (!vec->items)
		vec->items = calloc(1, sizeof(*vec->items));

	return vec->items;
}

static bool _buffer_put(buffer_t *buf, char c)
{
	if ((buf->len + 2) > buf->size) {
		size_t size = (buf->size ? (buf->size * 2) : 64);
		char *data = realloc(buf->data, size);

		if (!data)
			return false;

		buf->data = data;
		buf->size = size;
	}

	buf->data[buf->len++] = c;
	buf->data[buf->len] = '\0';
	return true;
}

static bool _buffer_puts(buffer_t *buf, const char *str)
{
	for (; *str; str++) {
		if (!_buffer_put(buf, *str))
			return false;
	}

	return true;
}

static void _set_error(char **errmsg, const char *fmt, ...)
	__attribute__((format(printf, 2, 3)));

static void _set_error(char **errmsg, const char *fmt, ...)
{
	va_list ap;

	if (!errmsg)
		return;

	va_start(ap, fmt);
	if (vasprintf(errmsg, fmt, ap) < 0)
		*errmsg = NULL;
	va_end(ap);
}

extern void command_free(char **argv)
{
	if (!argv)
		return;

	for (char **arg = argv; *arg; arg++)
		free(*arg);

	free(argv);
}

extern char **command_split_words(const char *str, char **errmsg)
{
	vector_t words = { 0 };
	buffer_t word = { 0 };
	bool in_word = false;
	char quote = '\0';

	if (errmsg)
		*errmsg = NULL;

	for (const char *p = (str ? str : ""); *p; p++) {
		const char c = *p;

		if (quote == '\'') {
			if (c == '\'')
				quote = '\0';
			else if (!_buffer_put(&word, c))
				goto no_memory;
		} else if (quote == '"') {
			if (c == '"') {
				quote = '\0';
			} else if ((c == '\\') &&
				   ((p[1] == '"') || (p[1] == '\\'))) {
				if (!_buffer_put(&word, *(++p)))
					goto no_memory;
			} else if (!_buffer_put(&word, c)) {
				goto no_memory;
			}
		} else if ((c == '\'') || (c == '"')) {
			/* An empty pair of quotes is an empty word. */
			quote = c;
			in_word = true;
		} else if (c == '\\') {
			if (!p[1]) {
				_set_error(errmsg, "backslash at the end of: %s",
					   str);
				goto failed;
			}
			if (!_buffer_put(&word, *(++p)))
				goto no_memory;
			in_word = true;
		} else if (isspace((unsigned char) c)) {
			if (in_word) {
				if (!_vector_push_copy(&words, (word.data ?
								word.data : "")))
					goto no_memory;
				word.len = 0;
				if (word.data)
					word.data[0] = '\0';
				in_word = false;
			}
		} else {
			if (!_buffer_put(&word, c))
				goto no_memory;
			in_word = true;
		}
	}

	if (quote) {
		_set_error(errmsg, "quote %c is not closed in: %s", quote, str);
		goto failed;
	}

	if (in_word && !_vector_push_copy(&words, (word.data ? word.data : "")))
		goto no_memory;

	free(word.data);

	if (!_vector_finish(&words))
		_set_error(errmsg, "out of memory");

	return words.items;

no_memory:
	_set_error(errmsg, "out of memory");
failed:
	free(word.data);
	command_free(words.items);
	return NULL;
}

/* Append the words of str. RET false on error with *errmsg set. */
static bool _push_words(vector_t *argv, const char *str, const char *what,
			char **errmsg)
{
	char *split_error = NULL;
	char **words = command_split_words(str, &split_error);
	bool ok = true;

	if (!words) {
		_set_error(errmsg, "%s: %s", what,
			   (split_error ? split_error : "invalid"));
		free(split_error);
		return false;
	}

	for (char **word = words; *word; word++) {
		/* The vector takes over the word. */
		if (ok && _vector_push(argv, *word))
			continue;
		ok = false;
		free(*word);
	}

	free(words);

	if (!ok)
		_set_error(errmsg, "out of memory");

	return ok;
}

/* Append "--bind spec" for each spec in a comma-separated list. */
static bool _push_binds(vector_t *argv, const char *specs)
{
	const char *start = specs;

	if (!specs)
		return true;

	while (true) {
		const char *end = strchr(start, ',');
		const size_t len = (end ? (size_t) (end - start) :
					  strlen(start));

		/* Skip empty entries, such as in "/a,,/b" or a trailing comma. */
		if (len) {
			char *spec = strndup(start, len);

			if (!spec || !_vector_push_copy(argv, "--bind") ||
			    !_vector_push(argv, spec)) {
				free(spec);
				return false;
			}
		}

		if (!end)
			return true;

		start = end + 1;
	}
}

extern bool command_image_is_none(const char *image)
{
	return (!image || !image[0] || !strcasecmp(image, COMMAND_IMAGE_NONE));
}

extern char **command_build(const command_t *cmd, char **errmsg)
{
	vector_t argv = { 0 };
	char *script_bind = NULL;

	if (errmsg)
		*errmsg = NULL;

	if (command_image_is_none(cmd->image)) {
		_set_error(errmsg, "no container image");
		return NULL;
	}

	if (!cmd->task_argv || !cmd->task_argv[0]) {
		_set_error(errmsg, "no command");
		return NULL;
	}

	if (!_vector_push_copy(&argv, (cmd->executable ? cmd->executable :
							 "apptainer")))
		goto no_memory;

	if (!_push_words(&argv, cmd->global_args, "global arguments", errmsg))
		goto failed;

	if (!_vector_push_copy(&argv, "exec"))
		goto no_memory;

	if (!_push_words(&argv, cmd->exec_args, "exec arguments", errmsg))
		goto failed;

	if (!cmd->no_default_binds && !_push_binds(&argv, cmd->default_binds))
		goto no_memory;

	if (cmd->script) {
		/*
		 * The batch script is a file in the spool directory of slurmd,
		 * which the image does not contain.
		 */
		if (asprintf(&script_bind, "%s:%s:ro", cmd->script,
			     cmd->script) < 0) {
			script_bind = NULL;
			goto no_memory;
		}

		if (!_vector_push_copy(&argv, "--bind") ||
		    !_vector_push(&argv, script_bind)) {
			free(script_bind);
			goto no_memory;
		}
	}

	/* A path is a bind spec with the same path in the container. */
	if (cmd->spool_dir && (!_vector_push_copy(&argv, "--bind") ||
			       !_vector_push_copy(&argv, cmd->spool_dir)))
		goto no_memory;

	if (!_push_binds(&argv, cmd->user_binds))
		goto no_memory;

	if (!_push_words(&argv, cmd->user_args, "user arguments", errmsg))
		goto failed;

	if (!_vector_push_copy(&argv, cmd->image))
		goto no_memory;

	for (char *const *arg = cmd->task_argv; *arg; arg++) {
		const bool first = (arg == cmd->task_argv);

		if (!_vector_push_copy(&argv, ((first && cmd->program) ?
						       cmd->program : *arg)))
			goto no_memory;
	}

	return argv.items;

no_memory:
	_set_error(errmsg, "out of memory");
failed:
	command_free(argv.items);
	return NULL;
}

static bool _is_program(const char *path)
{
	struct stat st;

	return (!stat(path, &st) && S_ISREG(st.st_mode) && !access(path, X_OK));
}

extern char *command_find_program(const char *program, const char *path)
{
	const char *start = path;

	if (!program || !program[0])
		return NULL;

	if (strchr(program, '/'))
		return strdup(program);

	if (!path)
		return NULL;

	while (true) {
		const char *end = strchr(start, ':');
		const size_t len = (end ? (size_t) (end - start) :
					  strlen(start));
		char *candidate = NULL;

		/* An empty entry means the working directory: never search it. */
		if (len) {
			if (asprintf(&candidate, "%.*s/%s", (int) len, start,
				     program) < 0)
				return NULL;

			if (_is_program(candidate))
				return candidate;

			free(candidate);
		}

		if (!end)
			return NULL;

		start = end + 1;
	}
}

extern bool command_parse_bool(const char *str, bool *value)
{
	static const char *yes[] = { "yes", "true", "on", "1", NULL };
	static const char *no[] = { "no", "false", "off", "0", NULL };

	if (!str)
		return false;

	for (int i = 0; yes[i]; i++) {
		if (!strcasecmp(str, yes[i])) {
			*value = true;
			return true;
		}
	}

	for (int i = 0; no[i]; i++) {
		if (!strcasecmp(str, no[i])) {
			*value = false;
			return true;
		}
	}

	return false;
}

/* RET true when a shell reads the word as it is */
static bool _is_plain_word(const char *word)
{
	if (!word[0])
		return false;

	for (const char *p = word; *p; p++) {
		if (!isalnum((unsigned char) *p) && !strchr("_-+=:,./@%", *p))
			return false;
	}

	return true;
}

extern char *command_join(char *const *argv)
{
	buffer_t line = { 0 };

	for (char *const *arg = argv; arg && *arg; arg++) {
		bool ok = ((arg == argv) || _buffer_put(&line, ' '));

		if (ok && _is_plain_word(*arg)) {
			ok = _buffer_puts(&line, *arg);
		} else if (ok) {
			ok = _buffer_put(&line, '\'');
			for (const char *p = *arg; ok && *p; p++) {
				if (*p == '\'')
					ok = _buffer_puts(&line, "'\\''");
				else
					ok = _buffer_put(&line, *p);
			}
			ok = (ok && _buffer_put(&line, '\''));
		}

		if (!ok) {
			free(line.data);
			return NULL;
		}
	}

	/* An empty vector gives an empty string, not NULL. */
	return (line.data ? line.data : strdup(""));
}
