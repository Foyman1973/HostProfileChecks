# HostProfileChecks
Report for checking VMware ESXi Host Profile Compliance and Scheduling

This script requires a CSV list of 1 or more vCenter instances, a config.xml file containing customization elements such as email information and report title, to pull a list of ESXi hosts and report on whether or not they have a host profile, if they have compliance issues with the attached profile as well as reporting if host profiles do not have a daily compliance scheduled task setup.

This report should be useful for tracking compliance shift across several vCenter environments where Host Profiles are employed for configuration management.
