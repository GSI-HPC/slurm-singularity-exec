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

# The runtime plugin interface is internal to Slurm. The plugin compiles
# against a configured Slurm source tree (config.h and slurm/slurm_version.h
# exist) of the release that loads it.
slurm_source = get_option('slurm_source')
if slurm_source == ''
  if get_option('plugin').enabled()
    error('The plugin needs -Dslurm_source=<configured Slurm source tree>')
  endif
  summary('runtime/apptainer plugin', false, bool_yn: true)
else
  fs = import('fs')
  foreach header : ['config.h', 'slurm/slurm_version.h', 'src/interfaces/runtime.h']
    if not fs.is_file(slurm_source / header)
      error(f'@slurm_source@/@header@ does not exist. Is the tree configured, and is it Slurm 26.11 or later?')
    endif
  endforeach

  plugindir = get_option('plugindir')
  if plugindir == ''
    plugindir = get_option('libdir') / 'slurm'
  endif

  # Slurm resolves the symbols of a plugin when it loads it, so the module
  # has undefined symbols (b_lundef=false) and no "lib" prefix.
  shared_module(
    'runtime_apptainer',
    'src/runtime_apptainer.c',
    name_prefix: '',
    dependencies: command_dep,
    include_directories: include_directories(slurm_source, is_system: true),
    c_args: ['-DHAVE_CONFIG_H', '-Wno-unused-parameter'],
    install: true,
    install_dir: plugindir,
  )

  install_data(
    'etc/apptainer.conf.example',
    install_dir: get_option('datadir') / 'doc' / meson.project_name(),
  )

  summary('runtime/apptainer plugin', true, bool_yn: true)
  summary('Slurm source', slurm_source)
  summary('Plugin directory', get_option('prefix') / plugindir)
endif
