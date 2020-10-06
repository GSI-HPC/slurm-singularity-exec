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
#include <utility>
#include <vector>

extern "C"
{
#include "spank.h"

  extern const char plugin_name[] = "singularity-exec";
  extern const char plugin_type[] = "spank";
  extern const unsigned int plugin_version = 0;
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
    SpankError(spank_err_t err) : errcode(err)
    {
      slurm_error("singularity-exec fatal error: %s", what());
    }

    const char*
    what() const noexcept override
    {
      return spank_strerror(errcode);
    }
  };

  bool
  is_remote() const
  {
    int r = spank_remote(handle);
    if (r < 0)
      throw InvalidHandle{};
    return r == 1;
  }

  std::pair<int, char**>
  job_arguments() const
  {
    std::pair<int, char**> job = { 0, nullptr };
    throw_on_error(
        spank_get_item(handle, S_JOB_ARGV, &job.first, &job.second));
    return job;
  }

  char**
  job_env() const
  {
    char** job_env;
    throw_on_error(spank_get_item(handle, S_JOB_ENV, &job_env));
    return job_env;
  }

  void
  setenv(const char* var, const char* val)
  {
    throw_on_error(spank_setenv(handle, var, val, 1));
  }

  void
  register_option(const char* name, const char* usage, int val,
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

  static int
  set_container_name(int, const char* optarg, int)
  {
    s_container_name = optarg;
    return 0;
  }

  static int
  init(Buttocks s, const ArgumentVector& args)
  {
    // slurm_info("singularity-exec init");
    for (std::string_view arg : args)
      {
        slurm_debug("singularity-exec argument: %s", arg.data());
        if (arg.starts_with("default="))
          {
            arg.remove_prefix(8);
            s_container_name = arg;
          }
        else if (arg.starts_with("script="))
          {
            arg.remove_prefix(7);
            s_singularity_script = arg;
          }
        else
          slurm_error("singularity-exec plugin: argument in plugstack.conf is "
                      "invalid: '%s'",
                      arg.data());
      }

    if (!s.is_remote())
      {
        slurm_verbose("singularity-exec: default = %s", s_container_name.c_str());
        s.register_option("singularity-exec", "<container>",
                          "name of the requested user space", 2,
                          set_container_name);
      }

    return 0;
  }

  static int
  setup_container(Buttocks s, const ArgumentVector&)
  {
    auto [job_n_arguments, job_arguments] = s.job_arguments();
    if (job_n_arguments < 1)
      {
        slurm_error("No job arguments given.");
        return ESPANK_ERROR;
      }
    s.setenv("SINGULARITY_EXEC_CONTAINER", s_container_name.c_str());
    s.setenv("SINGULARITY_EXEC_JOB", job_arguments[0]);
    job_arguments[0] = s_singularity_script.data();
    return 0;
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
  slurm_spank_task_init_privileged(spank_t sp, const int count, char* argv[])
  {
    return singularity_exec::setup_container(sp, { count, argv });
  }
}

// vim: foldmethod=indent sw=2 et
