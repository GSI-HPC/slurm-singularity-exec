/*{{{
    Copyright © 2020 GSI Helmholtzzentrum fuer Schwerionenforschung GmbH
                     Matthias Kretz <m.kretz@gsi.de>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

}}}*/

#include <cstring>
#include <exception>
#include <string>
#include <string_view>
#include <unistd.h>
#include <utility>
#include <vector>

extern "C"
{ // SPANK include
#include "spank.h"
}

/**
 * A type to wrap (argc, argv) into a proper container.
 */
class ArgumentVector : public std::vector<std::string_view>
{
public:
  ArgumentVector(const int n, char* args[])
  {
    reserve(n);
    for (int i = 0; i < n; ++i)
      emplace_back(args[i]);
  }
};

/**
 * A C++ wrapper for the SPANK API.
 */
class Buttocks
{
  spank_t handle;

  static void
  throw_on_error(spank_err_t err)
  {
    if (err != ESPANK_SUCCESS)
      throw SpankError(err);
  }

public:
  Buttocks(spank_t s) : handle(s) {}

  class InvalidHandle : public std::exception
  {
  public:
    const char*
    what() const noexcept override
    {
      return "invalid spank_t handle";
    }
  };

  class SpankError : public std::exception
  {
    const spank_err_t errcode;

  public:
    SpankError(spank_err_t err) : errcode(err) {}

    spank_err_t
    code() const noexcept
    {
      return errcode;
    }

    const char*
    what() const noexcept override
    {
      return spank_strerror(errcode);
    }
  };

  /// Return whether the plugin is in a remote context
  bool
  is_remote() const
  {
    int r = spank_remote(handle);
    if (r < 0)
      throw InvalidHandle{};
    return r == 1;
  }

  /// Return job arguments as (count, array of c strings) pair
  std::pair<int, char**>
  job_arguments() const
  {
    std::pair<int, char**> job = { 0, nullptr };
    throw_on_error(
        spank_get_item(handle, S_JOB_ARGV, &job.first, &job.second));
    return job;
  }

  /// Return job arguments as std::vector<c string>
  std::vector<char*>
  job_argument_vector() const
  {
    auto [n, args] = job_arguments();
    std::vector<char*> r;
    r.reserve(n);
    for (int i = 0; i < n; ++i)
      r.push_back(args[i]);
    return r;
  }

  /// Return all environment variables
  char**
  job_env() const
  {
    char** job_env;
    throw_on_error(spank_get_item(handle, S_JOB_ENV, &job_env));
    return job_env;
  }

  /// Set environment variable
  void
  setenv(const char* var, const char* val)
  {
    throw_on_error(spank_setenv(handle, var, val, 1));
  }

  /// Add option without argument to srun/sbatch
  void
  register_switch(const char* name, const char* usage, int val,
                  spank_opt_cb_f callback)
  {
    spank_option opt{ const_cast<char*>(name),
                      nullptr,
                      const_cast<char*>(usage),
                      false,
                      val,
                      callback };
    throw_on_error(spank_option_register(handle, &opt));
  }

  /// Add option with argument to srun/sbatch
  void
  register_option(const char* name, const char* arginfo, const char* usage,
                  int val, spank_opt_cb_f callback)
  {
    spank_option opt{ const_cast<char*>(name),
                      const_cast<char*>(arginfo),
                      const_cast<char*>(usage),
                      true,
                      val,
                      callback };
    throw_on_error(spank_option_register(handle, &opt));
  }
};

/**
 * The singularity-exec plugin.
 */
struct singularity_exec
{
  inline static std::string s_container_name = {};
  inline static std::string s_singularity_script = "/usr/lib/slurm/slurm-singularity-wrapper.sh";
  inline static std::string s_singularity_args = {};

  /// Set container name from --singularity-container
  static int
  set_container_name(int, const char* optarg, int)
  {
    s_container_name = optarg;
    return 0;
  }

  /// Set singularity arguments from --singularity-args
  static int
  set_singularity_args(int, const char* optarg, int)
  {
    s_singularity_args = optarg;
    return 0;
  }

  /// Initialize the plugin: read plugstack.conf config & register options
  static int
  init(Buttocks s, const ArgumentVector& args)
  {
    try
      {
        bool in_args = false;
        for (std::string_view arg : args)
          {
            slurm_debug("singularity-exec argument: %s", arg.data());
            if (in_args)
              {
                if (arg.ends_with('"'))
                  {
                    in_args = false;
                    arg.remove_suffix(1);
                  }
                (s_singularity_args += ' ') += arg;
              }
            else if (arg.starts_with("default="))
              {
                arg.remove_prefix(8);
                s_container_name = arg;
              }
            else if (arg.starts_with("script="))
              {
                arg.remove_prefix(7);
                s_singularity_script = arg;
              }
            else if (arg.starts_with("args=\""))
              {
                in_args = true;
                arg.remove_prefix(6);
                s_singularity_args = arg;
              }
            else
              slurm_error(
                  "singularity-exec plugin: argument in plugstack.conf is "
                  "invalid: '%s'",
                  arg.data());
          }

        s.register_option(
            "singularity-container", "<name>",
            ("name of the requested container / user space (default: '"
             + s_container_name + "')")
                .c_str(),
            0, set_container_name);
        s.register_option(
            "singularity-args", "<args>",
            ("arguments to pass to singularity when containerizing "
             "the job (default: '"
             + s_singularity_args + "')")
                .c_str(),
            0, set_singularity_args);

        return 0;
      }
    catch (const Buttocks::SpankError& err)
      {
        slurm_error("singularity-exec error: %s", err.what());
        return -err.code();
      }
  }

  /// execvpe the s_singularity_script for the job
  static int
  start_container(Buttocks s, const ArgumentVector&)
  {
    try
      {
        if (s_container_name.empty() || s_singularity_script.empty())
          {
            slurm_verbose("singularity-exec: no container selected. Skipping "
                          "start_container.");
            return 0;
          }

        s.setenv("SLURM_SINGULARITY_ARGS", s_singularity_args.c_str());
        std::vector<char*> argv = s.job_argument_vector();
        argv.insert(argv.begin(),
                    { s_singularity_script.data(), s_container_name.data() });
        argv.push_back(nullptr);
        if (-1
            == execvpe(s_singularity_script.c_str(), argv.data(), s.job_env()))
          {
            const auto error = std::strerror(errno);
            slurm_error("Starting %s in %s failed: %s", argv[0],
                        s_container_name.c_str(), error);
            return -ESPANK_ERROR;
          }
        __builtin_unreachable();
      }
    catch (const Buttocks::SpankError& err)
      {
        slurm_error("singularity-exec error: %s", err.what());
        return -err.code();
      }
  }
};

extern "C"
{ // SPANK plugin interface
  int
  slurm_spank_init(spank_t sp, const int count, char* argv[])
  {
    return singularity_exec::init(sp, { count, argv });
  }

  int
  slurm_spank_task_init(spank_t sp, const int argc, char* argv[])
  {
    return singularity_exec::start_container(sp, { argc, argv });
  }

  extern const char plugin_name[] = "singularity-exec";
  extern const char plugin_type[] = "spank";
  extern const unsigned int plugin_version = 0;
}

// vim: foldmethod=marker foldmarker={,} sw=2 et
