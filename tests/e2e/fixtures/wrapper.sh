#!/bin/sh
# Site wrapper for the Executable option of apptainer.conf: changes the
# environment of the container, then runs Apptainer with the arguments that
# the plugin made.
export APPTAINERENV_WRAPPER_MARK=set
exec apptainer "$@"
