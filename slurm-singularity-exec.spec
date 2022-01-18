Name:           slurm-singularity-exec
Version:        1.0
Release:        0
Summary:        Slurm SPANK plugin to start Singularity containers

License:        GPLv3
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  slurm-devel make gcc gcc-c++ libstdc++-static
Requires:       slurm-slurmd singularity

%description
The Singularity SPANK plug-in provides the users with an interface to launch an
application within a Singularity container. The plug-in adds multiple
command-line options to the salloc, srun and sbatch commands. These options are
then propagated to a shell script slurm-singularity-wrapper.sh customizable by
the cluster administrator.

%prep
%setup -q

%build
make

%install
rm -rf %{buildroot}

%changelog
* Mon Jan 17 2022 Victor Penso <v.penso@gsi.de> 1.0
  - First versions to be packaged
