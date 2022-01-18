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

%define  debug_package %{nil}

%prep
%setup -q

%build
make

%clean
rm -rf %{buildroot}

%install
mkdir -p %{buildroot}/%{_libdir} 
cp %{_builddir}/%{name}-%{version}/singularity-exec.so \
   %{buildroot}/%{_libdir}/singularity-exec.so
mkdir -p %{buildroot}/%{_libexecdir} 
cp %{_builddir}/%{name}-%{version}/slurm-singularity-wrapper.sh \
   %{buildroot}/%{_libexecdir}/slurm-singularity-wrapper.sh
mkdir -p %{buildroot}/%{_sysconfdir}/slurm/plugstack.conf.d
cp %{_builddir}/%{name}-%{version}/singularity-exec.conf \
   %{buildroot}/%{_sysconfdir}/slurm/plugstack.conf.d/singularity-exec.conf

%files
%{_libdir}/singularity-exec.so
%{_libexecdir}/slurm-singularity-wrapper.sh
%{_sysconfdir}/slurm/plugstack.conf.d/singularity-exec.conf

%changelog
* Mon Jan 17 2022 Victor Penso <v.penso@gsi.de> 1.0
  - First versions to be packaged
