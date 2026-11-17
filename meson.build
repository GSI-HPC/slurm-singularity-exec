# SPDX-License-Identifier: GPL-3.0-or-later
project(
  'slurm-runtime-apptainer',
  'c',
  version: '0.1.0',
  license: 'GPL-3.0-or-later',
  meson_version: '>=1.1',
  default_options: [
    'c_std=gnu11',
    'warning_level=2',
    'werror=true',
    'buildtype=debugoptimized',
    'b_lundef=false',
  ],
)

# The command line builder has no Slurm dependency, so the unit tests run
# without Slurm.
command_lib = static_library('command', 'src/command.c', pic: true)
command_dep = declare_dependency(
  link_with: command_lib,
  include_directories: include_directories('src'),
)

test(
  'command',
  executable('test_command', 'tests/unit/test_command.c', dependencies: command_dep),
)
