#!/bin/sh
# TaskProlog of the test cluster: sets a variable in the environment of each
# task. A task that does not have it did not get the TaskProlog.
echo "export TP_MARK=set"
