#!/bin/bash

## Install webserver and tar
sudo dnf -y install httpd tar
sudo systemctl enable --now httpd.service
sudo firewall-cmd --add-service=http --permanent
sudo firewall-cmd --reload

## Download and Install OpenShift Install and OC client
wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-install-linux.tar.gz
tar -xvf openshift-install-linux.tar.gz
sudo mv openshift-install /usr/local/bin/.

wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-client-linux.tar.gz
tar -xvf openshift-client-linux.tar.gz
sudo mv oc /usr/local/bin/.

## Install OCI client 
sudo dnf -y install oraclelinux-developer-release-el8
sudo dnf install python36-oci-cli