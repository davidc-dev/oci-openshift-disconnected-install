terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.38.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.11.1"
    }
    aws = {
      source = "hashicorp/aws"
      version = ">= 5.64.0"
    }
  }
}


# Oracle Cloud Infrastructure Terraform Provider

provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  user_ocid = var.user_ocid
  private_key_path = "~/.oci/ocikey.pem"
  fingerprint = var.oci_fingerprint
  region = var.region
}


## Oracle Cloud Identity Config

data "oci_identity_tenancy" "tenancy" {
  tenancy_id = var.tenancy_ocid
}

data "oci_identity_regions" "regions" {}

locals {
  all_protocols                   = "all"
  anywhere                        = "0.0.0.0/0"
}


data "oci_identity_availability_domain" "availability_domain" {
  compartment_id = var.compartment_ocid
  ad_number      = "1"
}

##Defined tag namespace. Use to mark instance roles and configure instance policy
resource "oci_identity_tag_namespace" "openshift_tags" {
  compartment_id = var.compartment_ocid
  description    = "Used for track openshift related resources and policies"
  is_retired     = "false"
  name           = "openshift-${var.cluster_name}"
}

resource "oci_identity_tag" "openshift_instance_role" {
  description      = "Describe instance role inside OpenShift cluster"
  is_cost_tracking = "false"
  is_retired       = "false"
  name             = "instance-role"
  tag_namespace_id = oci_identity_tag_namespace.openshift_tags.id
  validator {
    validator_type = "ENUM"
    values = [
      "control_plane",
      "compute",
    ]
  }
}


##Define network
resource "oci_core_vcn" "openshift_vcn" {
  cidr_blocks = [
    var.vcn_cidr,
  ]
  compartment_id = var.compartment_ocid
  display_name   = var.cluster_name
  dns_label      = var.vcn_dns_label
}

resource "oci_core_internet_gateway" "internet_gateway" {
  compartment_id = var.compartment_ocid
  display_name   = "InternetGateway"
  vcn_id         = oci_core_vcn.openshift_vcn.id
}

resource "oci_core_nat_gateway" "nat_gateway" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openshift_vcn.id
  display_name   = "NatGateway"
}

data "oci_core_services" "oci_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "service_gateway" {
  #Required
  compartment_id = var.compartment_ocid

  services {
    service_id = data.oci_core_services.oci_services.services[0]["id"]
  }

  vcn_id = oci_core_vcn.openshift_vcn.id

  display_name = "ServiceGateway"
}

resource "oci_core_route_table" "public_routes" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openshift_vcn.id
  display_name   = "public"

  route_rules {
    destination       = local.anywhere
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.internet_gateway.id
  }
}

resource "oci_core_route_table" "private_routes" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openshift_vcn.id
  display_name   = "private"

  route_rules {
    destination       = local.anywhere
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat_gateway.id
  }
  route_rules {
    destination       = data.oci_core_services.oci_services.services[0]["cidr_block"]
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.service_gateway.id
  }
}

resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_ocid
  display_name   = "private"
  vcn_id         = oci_core_vcn.openshift_vcn.id

  ingress_security_rules {
    source   = var.vcn_cidr
    protocol = local.all_protocols
  }
  egress_security_rules {
    destination = local.anywhere
    protocol    = local.all_protocols
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  display_name   = "public"
  vcn_id         = oci_core_vcn.openshift_vcn.id

  ingress_security_rules {
    source   = var.vcn_cidr
    protocol = local.all_protocols
  }
  ingress_security_rules {
    source   = local.anywhere
    protocol = "6"
    tcp_options {
      min = 22
      max = 22
    }
  }
  egress_security_rules {
    destination = local.anywhere
    protocol    = local.all_protocols
  }
}

resource "oci_core_subnet" "private" {
  cidr_block     = var.private_cidr
  display_name   = "private"
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openshift_vcn.id
  route_table_id = oci_core_route_table.private_routes.id

  security_list_ids = [
    oci_core_security_list.private.id,
  ]

  dns_label                  = "private"
  prohibit_public_ip_on_vnic = true
}

resource "oci_core_subnet" "public" {
  cidr_block     = var.public_cidr
  display_name   = "public"
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openshift_vcn.id
  route_table_id = oci_core_route_table.public_routes.id

  security_list_ids = [
    oci_core_security_list.public.id,
  ]

  dns_label                  = "public"
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_network_security_group" "cluster_lb_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openshift_vcn.id
  display_name   = "cluster-lb-nsg"
}

resource "oci_core_network_security_group_security_rule" "cluster_lb_nsg_rule_1" {
  network_security_group_id = oci_core_network_security_group.cluster_lb_nsg.id
  direction                 = "EGRESS"
  destination               = local.anywhere
  protocol                  = local.all_protocols
}

resource "oci_core_network_security_group_security_rule" "cluster_lb_nsg_rule_2" {
  network_security_group_id = oci_core_network_security_group.cluster_lb_nsg.id
  protocol                  = "6"
  direction                 = "INGRESS"
  source                    = local.anywhere
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cluster_lb_nsg_rule_3" {
  network_security_group_id = oci_core_network_security_group.cluster_lb_nsg.id
  protocol                  = "6"
  direction                 = "INGRESS"
  source                    = local.anywhere
  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cluster_lb_nsg_rule_4" {
  network_security_group_id = oci_core_network_security_group.cluster_lb_nsg.id
  protocol                  = "6"
  direction                 = "INGRESS"
  source                    = local.anywhere
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cluster_lb_nsg_rule_5" {
  network_security_group_id = oci_core_network_security_group.cluster_lb_nsg.id
  protocol                  = local.all_protocols
  direction                 = "INGRESS"
  source                    = var.vcn_cidr
}

resource "oci_core_network_security_group" "cluster_controlplane_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openshift_vcn.id
  display_name   = "cluster-controlplane-nsg"
}

resource "oci_core_network_security_group_security_rule" "cluster_controlplane_nsg_rule_1" {
  network_security_group_id = oci_core_network_security_group.cluster_controlplane_nsg.id
  direction                 = "EGRESS"
  destination               = local.anywhere
  protocol                  = local.all_protocols
}

resource "oci_core_network_security_group_security_rule" "cluster_controlplane_nsg_2" {
  network_security_group_id = oci_core_network_security_group.cluster_controlplane_nsg.id
  protocol                  = local.all_protocols
  direction                 = "INGRESS"
  source                    = var.vcn_cidr
}

resource "oci_core_network_security_group" "cluster_compute_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openshift_vcn.id
  display_name   = "cluster-compute-nsg"
}

resource "oci_core_network_security_group_security_rule" "cluster_compute_nsg_rule_1" {
  network_security_group_id = oci_core_network_security_group.cluster_compute_nsg.id
  direction                 = "EGRESS"
  destination               = local.anywhere
  protocol                  = local.all_protocols
}

resource "oci_core_network_security_group_security_rule" "cluster_compute_nsg_2" {
  network_security_group_id = oci_core_network_security_group.cluster_compute_nsg.id
  protocol                  = local.all_protocols
  direction                 = "INGRESS"
  source                    = var.vcn_cidr
}

resource "oci_load_balancer_load_balancer" "openshift_api_int_lb" {
  compartment_id             = var.compartment_ocid
  display_name               = "${var.cluster_name}-openshift_api_int_lb"
  shape                      = "flexible"
  subnet_ids                 = [oci_core_subnet.private.id]
  is_private                 = true
  network_security_group_ids = [oci_core_network_security_group.cluster_lb_nsg.id]

  shape_details {
    maximum_bandwidth_in_mbps = var.load_balancer_shape_details_maximum_bandwidth_in_mbps
    minimum_bandwidth_in_mbps = var.load_balancer_shape_details_minimum_bandwidth_in_mbps
  }
}


## External/Public Load Balancer
resource "oci_load_balancer_load_balancer" "openshift_api_apps_lb" {
  compartment_id             = var.compartment_ocid
  display_name               = "${var.cluster_name}-openshift_api_apps_lb"
  shape                      = "flexible"
  subnet_ids                 = var.enable_private_dns ? [oci_core_subnet.private.id] : [oci_core_subnet.public.id]
  is_private                 = var.enable_private_dns ? true : false
  network_security_group_ids = [oci_core_network_security_group.cluster_lb_nsg.id]

  shape_details {
    maximum_bandwidth_in_mbps = var.load_balancer_shape_details_maximum_bandwidth_in_mbps
    minimum_bandwidth_in_mbps = var.load_balancer_shape_details_minimum_bandwidth_in_mbps
  }
}

## External Loadbalancer Backend Config - API
resource "oci_load_balancer_backend_set" "openshift_cluster_api_backend_external" {
  health_checker {
    protocol          = "HTTP"
    port              = 6080
    return_code       = 200
    url_path          = "/readyz"
    interval_ms       = 10000
    timeout_in_millis = 3000
    retries           = 3
  }
  name             = "openshift_cluster_api_backend"
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
  policy           = "LEAST_CONNECTIONS"
}
## External Loadbalancer Backend Config - API
resource "oci_load_balancer_backend" "master-01-api-external" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_api_backend_external.name
  ip_address = oci_core_instance.bootstrap-node-master-00.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
  port = 6443
}

resource "oci_load_balancer_backend" "master-02-api-external" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_api_backend_external.name
  ip_address = oci_core_instance.master-01.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
  port = 6443
}

resource "oci_load_balancer_backend" "master-03-api-external" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_api_backend_external.name
  ip_address = oci_core_instance.master-02.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
  port = 6443
}

## External Loadbalancer Listener Config - API
resource "oci_load_balancer_listener" "openshift_cluster_api_listener_external" {
  default_backend_set_name = oci_load_balancer_backend_set.openshift_cluster_api_backend_external.name
  name                     = "openshift_cluster_api_listener"
  load_balancer_id         = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
  port                     = 6443
  protocol                 = "TCP"
}

## External Loadbalancer Backend Config - http
resource "oci_load_balancer_backend_set" "openshift_cluster_ingress_http_backend" {
  health_checker {
    protocol          = "TCP"
    port              = 80
    interval_ms       = 10000
    timeout_in_millis = 3000
    retries           = 3
  }
  name             = "openshift_cluster_ingress_http"
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
  policy           = "LEAST_CONNECTIONS"
}

## Load Balancer Backend Config

# resource "oci_load_balancer_backend" "master-00-http-external" {
#   backendset_name = oci_load_balancer_backend_set.openshift_cluster_ingress_http_backend.name
#   ip_address = oci_core_instance.bootstrap-node-master-00.private_ip
#   load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
#   port = 80
# }
# resource "oci_load_balancer_backend" "master-01-http-external" {
#   backendset_name = oci_load_balancer_backend_set.openshift_cluster_ingress_http_backend.name
#   ip_address = oci_core_instance.master-01.private_ip
#   load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
#   port = 80
# }
# resource "oci_load_balancer_backend" "master-02-http-external" {
#   backendset_name = oci_load_balancer_backend_set.openshift_cluster_ingress_http_backend.name
#   ip_address = oci_core_instance.master-02.private_ip
#   load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
#   port = 80
# }

##  Worker Nodes http load balancer backend config
resource "oci_load_balancer_backend" "worker-01-http-external" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_ingress_http_backend.name
  ip_address = oci_core_instance.worker-01.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
  port = 80
}

resource "oci_load_balancer_backend" "worker-02-http-external" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_ingress_http_backend.name
  ip_address = oci_core_instance.worker-02.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
  port = 80
}

## External Loadbalancer Listener Config - http
resource "oci_load_balancer_listener" "openshift_cluster_ingress_http" {
  default_backend_set_name = oci_load_balancer_backend_set.openshift_cluster_ingress_http_backend.name
  name                     = "openshift_cluster_ingress_http"
  load_balancer_id         = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
  port                     = 80
  protocol                 = "TCP"
}

## External Loadbalancer Backend Config - HTTPS
resource "oci_load_balancer_backend_set" "openshift_cluster_ingress_https_backend" {
  health_checker {
    protocol          = "TCP"
    port              = 443
    interval_ms       = 10000
    timeout_in_millis = 3000
    retries           = 3
  }
  name             = "openshift_cluster_ingress_https"
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
  policy           = "LEAST_CONNECTIONS"
}

## TEmp for masters at first install

# resource "oci_load_balancer_backend" "master-00-https-external" {
#   backendset_name = oci_load_balancer_backend_set.openshift_cluster_ingress_https_backend.name
#   ip_address = "10.0.16.100"
#   load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
#   port = 443
# }
# resource "oci_load_balancer_backend" "master-01-https-external" {
#   backendset_name = oci_load_balancer_backend_set.openshift_cluster_ingress_https_backend.name
#   ip_address = "10.0.16.101"
#   load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
#   port = 443
# }
# resource "oci_load_balancer_backend" "master-02-https-external" {
#   backendset_name = oci_load_balancer_backend_set.openshift_cluster_ingress_https_backend.name
#   ip_address = "10.0.16.102"
#   load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
#   port = 443
# }
##

resource "oci_load_balancer_backend" "worker-01-https-external" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_ingress_https_backend.name
  ip_address = oci_core_instance.worker-01.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
  port = 443
}

resource "oci_load_balancer_backend" "worker-02-https-external" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_ingress_https_backend.name
  ip_address = oci_core_instance.worker-02.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
  port = 443
}

## External Loadbalancer Listener Config - HTTPS
resource "oci_load_balancer_listener" "openshift_cluster_ingress_https" {
  default_backend_set_name = oci_load_balancer_backend_set.openshift_cluster_ingress_https_backend.name
  name                     = "openshift_cluster_ingress_https"
  load_balancer_id         = oci_load_balancer_load_balancer.openshift_api_apps_lb.id
  port                     = 443
  protocol                 = "TCP"
}

## Internal Loadbalancer Backend Config - API
resource "oci_load_balancer_backend_set" "openshift_cluster_api_backend_internal" {
  health_checker {
    protocol          = "HTTP"
    port              = 6080
    return_code       = 200
    url_path          = "/readyz"
    interval_ms       = 10000
    timeout_in_millis = 3000
    retries           = 3
  }
  name             = "openshift_cluster_api_backend"
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  policy           = "LEAST_CONNECTIONS"
}

resource "oci_load_balancer_backend" "master-01-api-internal" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_api_backend_internal.name
  ip_address = oci_core_instance.bootstrap-node-master-00.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  port = 6443
}

resource "oci_load_balancer_backend" "master-02-api-internal" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_api_backend_internal.name
  ip_address = oci_core_instance.master-01.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  port = 6443
}

resource "oci_load_balancer_backend" "master-03-api-internal" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_api_backend_internal.name
  ip_address = oci_core_instance.master-02.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  port = 6443
}

## Internal Loadbalancer Litener Config - API
resource "oci_load_balancer_listener" "openshift_cluster_api_listener_internal" {
  default_backend_set_name = oci_load_balancer_backend_set.openshift_cluster_api_backend_internal.name
  name                     = "openshift_cluster_api_listener"
  load_balancer_id         = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  port                     = 6443
  protocol                 = "TCP"
}

## Internal Loadbalancer Backend Config - Infra MCS 
resource "oci_load_balancer_backend_set" "openshift_cluster_infra-mcs_backend" {
  health_checker {
    protocol          = "HTTP"
    port              = 22624
    return_code       = 200
    url_path          = "/healthz"
    interval_ms       = 10000
    timeout_in_millis = 3000
    retries           = 3
  }
  name             = "openshift_cluster_infra-mcs"
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  policy           = "LEAST_CONNECTIONS"
}

resource "oci_load_balancer_backend" "master-01-infra-mcs" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_infra-mcs_backend.name
  ip_address = oci_core_instance.bootstrap-node-master-00.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  port = 22623
}

resource "oci_load_balancer_backend" "master-02-infra-mcs" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_infra-mcs_backend.name
  ip_address = oci_core_instance.master-01.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  port = 22623
}

resource "oci_load_balancer_backend" "master-03-infra-mcs" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_infra-mcs_backend.name
  ip_address = oci_core_instance.master-02.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  port = 22623
}

## Internal Loadbalancer Listener Config - Infra MCS 
resource "oci_load_balancer_listener" "openshift_cluster_infra-mcs" {
  default_backend_set_name = oci_load_balancer_backend_set.openshift_cluster_infra-mcs_backend.name
  name                     = "openshift_cluster_infra-mcs"
  load_balancer_id         = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  port                     = 22623
  protocol                 = "TCP"
}

## Internal Loadbalancer Backend Config - Infra MCS 2
resource "oci_load_balancer_backend_set" "openshift_cluster_infra-mcs_backend_2" {
  health_checker {
    protocol          = "HTTP"
    port              = 22624
    return_code       = 200
    url_path          = "/healthz"
    interval_ms       = 10000
    timeout_in_millis = 3000
    retries           = 3
  }
  name             = "openshift_cluster_infra-mcs_2"
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  policy           = "LEAST_CONNECTIONS"
}

resource "oci_load_balancer_backend" "master-01-infra-mcs-2" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_infra-mcs_backend_2.name
  ip_address = oci_core_instance.bootstrap-node-master-00.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  port = 22624
}

resource "oci_load_balancer_backend" "master-02-infra-mcs-2" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_infra-mcs_backend_2.name
  ip_address = oci_core_instance.master-01.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  port = 22624
}

resource "oci_load_balancer_backend" "master-03-infra-mcs-2" {
  backendset_name = oci_load_balancer_backend_set.openshift_cluster_infra-mcs_backend_2.name
  ip_address = oci_core_instance.master-02.private_ip
  load_balancer_id = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  port = 22624
}

## Internal Loadbalancer Listener Config - Infra MCS 2
resource "oci_load_balancer_listener" "openshift_cluster_infra-mcs_2" {
  default_backend_set_name = oci_load_balancer_backend_set.openshift_cluster_infra-mcs_backend_2.name
  name                     = "openshift_cluster_infra-mcs_2"
  load_balancer_id         = oci_load_balancer_load_balancer.openshift_api_int_lb.id
  port                     = 22624
  protocol                 = "TCP"
}


## Dynamic Group Config

resource "oci_identity_dynamic_group" "openshift_control_plane_nodes" {
  compartment_id = var.tenancy_ocid
  description    = "OpenShift control_plane nodes"
  matching_rule  = "all {instance.compartment.id='${var.compartment_ocid}', tag.openshift-${var.cluster_name}.instance-role.value='control_plane'}"
  name           = "${var.cluster_name}_control_plane_nodes"
}

resource "oci_identity_policy" "openshift_control_plane_nodes" {
  compartment_id = var.compartment_ocid
  description    = "OpenShift control_plane nodes instance principal"
  name           = "${var.cluster_name}_control_plane_nodes"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.openshift_control_plane_nodes.name} to manage volume-family in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.openshift_control_plane_nodes.name} to manage instance-family in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.openshift_control_plane_nodes.name} to manage security-lists in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.openshift_control_plane_nodes.name} to use virtual-network-family in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.openshift_control_plane_nodes.name} to manage load-balancers in compartment id ${var.compartment_ocid}",
  ]
}

resource "oci_identity_dynamic_group" "openshift_compute_nodes" {
  compartment_id = var.tenancy_ocid
  description    = "OpenShift compute nodes"
  matching_rule  = "all {instance.compartment.id='${var.compartment_ocid}', tag.openshift-${var.cluster_name}.instance-role.value='compute'}"
  name           = "${var.cluster_name}_compute_nodes"
}

resource "time_sleep" "wait_180_seconds" {
  depends_on      = [oci_core_vcn.openshift_vcn]
  create_duration = "180s"
}

## Object storage bucket for images

data "oci_objectstorage_namespace" "ocp_namespace" {

    #Optional
    compartment_id = var.compartment_ocid
}

resource "oci_objectstorage_bucket" "ocp_images_bucket" {
    #Required
    compartment_id = var.compartment_ocid
    name = var.bucket_name
    namespace = data.oci_objectstorage_namespace.ocp_namespace.namespace
}



## Web Server for creating OCP install images and hosting rootfs and ignition files

module "webserver" {
  source ="./modules/webserver"
  webserver_availability_domain = data.oci_identity_availability_domain.availability_domain.name
  webserver_compartment_ocid    = var.compartment_ocid
  webserver_shape               = var.control_plane_shape
  webserver_display_name        = "webserver"
  webserver_private_ip          = "10.0.0.200"
  webserver_assign_public_ip    = true
  webserver_subnet_id           = oci_core_subnet.public.id
  webserver_memory_in_gbs       = 8
  webserver_ocpus               = 2
  webserver_image_source_id     = "ocid1.image.oc1.us-sanjose-1.aaaaaaaawh277nw64u75z2eue7mog2oqwh7jjezfyb74ugx2m6f6lxskhcza"
  webserver_source_type         = "image"
  webserver_metadata            = {"ssh_authorized_keys": "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC5dW6nAe76ZspOQXcckuYcQFst90D7GeAfL1TN+48DJC34eBjIw+HIbuKGEWHOMnSe/gnPKyBNu9vxvlZd29HSeDG2qvVNna059tZ0cQOBBdbp0d5x86vEo0tW/kH9aVDS00RPqbyhf1oHySn0etS32kKdnAl4CNlrfOI47B6tCUlXjSTfh3tXaAgBl3/4Yn3rrDVfmnuTJHfZw8W3XxG1r9F6eBzSLREeey+gdLQ7kIqsysy42ELy9+LSmRgtnydRFnawiQp05d8FvJ0O6gfwEnzIJv5UL4GpfgmsMg2X3ZoHP/unW0eIaPUAZkyE+d6DEhfTl/B6kZOiKjA5GZvTpKZsdiXtHV5V7H+PvdmkbQywHt69SAlk/S8xn1HEHTA8stU3vlpAM2B7IV/AXVeEIT+kR4mUhnh0lrdthOutRNd1b7ZD11nZHZHjuFY3F7xfatTZ0V8pV+9c3DE7za70bP2EWma9c0xgbC1Iqr2BPrrBcsXm2Woe2nw3plFJc80="}
}


### Configure Ansible Vars 


resource "null_resource" "ansible_vars" {
  provisioner "local-exec" {
    command = <<-EOT
      cat > ${path.module}/ansible/oci-webserver-config-ansible/group_vars/all <<EOL
      ## webserver setup vars
      oci_user_ocid: ${var.user_ocid}
      oci_config_fingerprint: ${var.oci_fingerprint}
      oci_tenancy_ocid: ${var.tenancy_ocid}
      oci_region: ${var.region}
      oci_config_privatekey_pem: | 
      ${var.oci_config_private_key}
      ocp_version: ${var.ocp_version}
      ## openshift image create vars
      base_domain: ${var.zone_dns}
      cluster_name: ${var.cluster_name}
      vnet_cidr: ${oci_core_subnet.private.cidr_block}
      worker_count: ${var.compute_count}
      master_count: ${var.control_plane_count}
      ssh_pub_key: ${var.ssh_pub_key}
      pull_secret: ${var.pull_secret}
      mirrors: ${var.mirrors}
      webserver_private_ip: ${module.webserver.webserver_private_ip}
      rendezvousIP: ${var.rendezvousIP}
      compartment_ocid: ${var.compartment_ocid}
      vcn_ocid: ${oci_core_vcn.openshift_vcn.id}
      load_balancer_subnet_ocid: ${oci_core_subnet.public.id}
      load_balancer_security_list_ocid: ${oci_core_security_list.public.id}
      oci_bucket_name: ${var.bucket_name}
    EOT
  }

  provisioner "local-exec" {
    command = "sed -i '/^$/d' ${path.module}/ansible/oci-webserver-config-ansible/group_vars/all"
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat > ${path.module}/ansible/oci-webserver-config-ansible/id_rsa <<EOL
      ${var.webserver_private_key}
    EOT
    }

  provisioner "local-exec" {
    command = "chmod 600 ${path.module}/ansible/oci-webserver-config-ansible/id_rsa"
    }

  provisioner "local-exec" {
    command = <<-EOT
    cat > ${path.module}/ansible/oci-webserver-config-ansible/inventory.yml <<EOL
    webserver:
      hosts:
        ${module.webserver.webserver_public_ip}: 
          ansible_connection: ssh 
          ansible_user: opc
    EOT
  }

  provisioner "local-exec" {
    when = destroy
    command = <<-EOT
    rm -f ${path.module}/ansible/oci-webserver-config-ansible/group_vars/all \
    ${path.module}/ansible/oci-webserver-config-ansible/id_rsa \
    ${path.module}/ansible/oci-webserver-config-ansible/inventory.yml
    EOT
  }
depends_on = [ module.webserver ]
}

data "local_file" "webserver_pem_key" {
    filename = "${path.module}/ansible/oci-webserver-config-ansible/id_rsa"
  depends_on = [ null_resource.ansible_vars ]
}

## Run Ansible Role to configure webserver, create OCP install image and copy to object storage

resource "null_resource" "ansible_config" {
  provisioner "local-exec" {
    command = <<-EOT
      ansible-playbook -i ${path.module}/ansible/oci-webserver-config-ansible/inventory.yml \
      -e "ansible_user=opc" -e "ansible_ssh_private_key_file=${path.module}/ansible/oci-webserver-config-ansible/id_rsa" \
      -e "ansible_ssh_extra_args='-o StrictHostKeyChecking=no'" \
      ${path.module}/ansible/oci-webserver-config-ansible/configure-webserver.yml
    EOT
  }
  
  provisioner "local-exec" {
    when = destroy
    command = <<-EOT
      ansible-playbook -i ${path.module}/ansible/oci-webserver-config-ansible/inventory.yml \
      -e "ansible_user=opc" -e "ansible_ssh_private_key_file=${path.module}/ansible/oci-webserver-config-ansible/id_rsa" \
      -e "ansible_ssh_extra_args='-o StrictHostKeyChecking=no'" \
      ${path.module}/ansible/oci-webserver-config-ansible/cleanup-environment.yml
    EOT
  }

depends_on = [ oci_load_balancer_backend_set.openshift_cluster_api_backend_external, module.webserver, null_resource.ansible_vars, oci_objectstorage_bucket.ocp_images_bucket]
}


##  AWS Config for Route53 DNS

provider "aws" {
  region = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

data "aws_route53_zone" "primary" {
  name         = var.zone_dns
  private_zone = false
}

resource "aws_route53_record" "apps-record" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "*.apps.${var.cluster_name}.${var.zone_dns}"
  type    = "A"
  ttl     = 300
  records = [oci_load_balancer_load_balancer.openshift_api_apps_lb.ip_address_details[0].ip_address]
}

resource "aws_route53_record" "api-record" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "api.${var.cluster_name}.${var.zone_dns}"
  type    = "A"
  ttl     = 300
  records = [oci_load_balancer_load_balancer.openshift_api_apps_lb.ip_address_details[0].ip_address]
}

resource "aws_route53_record" "api-int-record" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "api-int.${var.cluster_name}.${var.zone_dns}"
  type    = "A"
  ttl     = 300
  records = [oci_load_balancer_load_balancer.openshift_api_int_lb.ip_address_details[0].ip_address]
}

### OpenShift Installer - Oracle Custom Image creation

resource "oci_objectstorage_preauthrequest" "ocp_install_image_preauthenticated_request" {
    #Required
    access_type = "ObjectRead"
    bucket = var.bucket_name
    name = "ocp-install-image-iso-preauth"
    namespace = data.oci_objectstorage_namespace.ocp_namespace.namespace
    time_expires = "${formatdate("YYYY-MM-DD", timeadd(timestamp(), "24h"))}T00:00:00Z"
    object_name = "agent.x86_64.iso"
    depends_on = [ null_resource.ansible_config ]
    lifecycle {
      ignore_changes = [ time_expires ]
    }
}

data "oci_core_compute_global_image_capability_schemas" "image_capability_schemas" {
}

locals {
  global_image_capability_schemas = data.oci_core_compute_global_image_capability_schemas.image_capability_schemas.compute_global_image_capability_schemas
  image_schema_data = {
    "Compute.Firmware" = "{\"values\": [\"UEFI_64\"],\"defaultValue\": \"UEFI_64\",\"descriptorType\": \"enumstring\",\"source\": \"IMAGE\"}"
  }
}

resource "oci_core_image" "openshift_image" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-openshift-image"
  launch_mode    = "PARAVIRTUALIZED"

  image_source_details {
    source_type = "objectStorageUri"
    source_uri  = oci_objectstorage_preauthrequest.ocp_install_image_preauthenticated_request.full_path
    source_image_type = "QCOW2"
  }
}

resource "oci_core_shape_management" "imaging_control_plane_shape" {
  compartment_id = var.compartment_ocid
  image_id       = oci_core_image.openshift_image.id
  shape_name     = var.control_plane_shape
}

resource "oci_core_compute_image_capability_schema" "openshift_image_capability_schema" {
  compartment_id                                      = var.compartment_ocid
  compute_global_image_capability_schema_version_name = local.global_image_capability_schemas[0].current_version_name
  image_id                                            = oci_core_image.openshift_image.id
  schema_data                                         = local.image_schema_data
}


## Control Plane Nodes

# Bootstrap / Master 00
resource "oci_core_instance" "bootstrap-node-master-00" {
  availability_domain = data.oci_identity_availability_domain.availability_domain.name
  compartment_id      = var.compartment_ocid
  shape = var.control_plane_shape
  display_name = "master-00"
  create_vnic_details {
    private_ip          = "10.0.16.100"
    assign_public_ip    = "false"
    assign_private_dns_record = false
    nsg_ids = [
      oci_core_network_security_group.cluster_controlplane_nsg.id,
    ]
    subnet_id = oci_core_subnet.private.id
  }      
  defined_tags = {
    "openshift-${var.cluster_name}.instance-role" = "control_plane"
  }
  shape_config {
    memory_in_gbs = var.control_plane_memory
    ocpus         = var.control_plane_ocpu
  }
  source_details {
    boot_volume_size_in_gbs = var.control_plane_boot_size
    boot_volume_vpus_per_gb = var.control_plane_boot_volume_vpus_per_gb
    source_id                = oci_core_image.openshift_image.id
    source_type             = "image"
  }


}


##  Other Master Nodes
resource "oci_core_instance" "master-01" {
  availability_domain = data.oci_identity_availability_domain.availability_domain.name
  compartment_id      = var.compartment_ocid
  shape = var.control_plane_shape
  display_name = "master-01"
  create_vnic_details {
    private_ip          = "10.0.16.101"
    assign_public_ip    = "false"
    assign_private_dns_record = false
    nsg_ids = [
      oci_core_network_security_group.cluster_controlplane_nsg.id,
    ]
    subnet_id = oci_core_subnet.private.id
  }      
  defined_tags = {
    "openshift-${var.cluster_name}.instance-role" = "control_plane"
  }
  shape_config {
    memory_in_gbs = var.control_plane_memory
    ocpus         = var.control_plane_ocpu
  }
  source_details {
    boot_volume_size_in_gbs = var.control_plane_boot_size
    boot_volume_vpus_per_gb = var.control_plane_boot_volume_vpus_per_gb
    source_id                = oci_core_image.openshift_image.id
    source_type             = "image"
  }

}

resource "oci_core_instance" "master-02" {
  availability_domain = data.oci_identity_availability_domain.availability_domain.name
  compartment_id      = var.compartment_ocid
  shape = var.control_plane_shape
    display_name = "master-02"
  create_vnic_details {
    private_ip          = "10.0.16.102"
    assign_public_ip    = "false"
    assign_private_dns_record = false
    nsg_ids = [
      oci_core_network_security_group.cluster_controlplane_nsg.id,
    ]
    subnet_id = oci_core_subnet.private.id
  }      
  defined_tags = {
    "openshift-${var.cluster_name}.instance-role" = "control_plane"
  }
  shape_config {
    memory_in_gbs = var.control_plane_memory
    ocpus         = var.control_plane_ocpu
  }
  source_details {
    boot_volume_size_in_gbs = var.control_plane_boot_size
    boot_volume_vpus_per_gb = var.control_plane_boot_volume_vpus_per_gb
    source_id                = oci_core_image.openshift_image.id
    source_type             = "image"
  }

}



## Wait for original OCP install to finish
resource "null_resource" "openshift-install-complete" {
  connection {
    type  =  "ssh"
    user  =  "opc"
    host  =  module.webserver.webserver_public_ip
    private_key = data.local_file.webserver_pem_key.content
  }
  provisioner "remote-exec" {
    inline = [
      "cd ~/${var.cluster_name}",
      "sleep 300",
      "openshift-install agent wait-for install-complete"
    ]
  }
  depends_on = [ oci_core_instance.bootstrap-node-master-00, null_resource.ansible_config, data.local_file.webserver_pem_key, null_resource.ansible_vars ]
}

## Ansibel role to create worker image and copy to objectstorage

resource "null_resource" "worker_image_config" {
  provisioner "local-exec" {
    command = <<-EOT
      ansible-playbook -i ${path.module}/ansible/oci-webserver-config-ansible/inventory.yml \
      -e "ansible_user=opc" -e "ansible_ssh_private_key_file=${path.module}/ansible/oci-webserver-config-ansible/id_rsa" \
      -e "ansible_ssh_extra_args='-o StrictHostKeyChecking=no'" \
      ${path.module}/ansible/oci-webserver-config-ansible/create-worker-image.yml
    EOT
  }

depends_on = [ null_resource.openshift-install-complete, null_resource.ansible_vars ]
}

## preauthenticated URL for worker image
resource "oci_objectstorage_preauthrequest" "ocp_worker_image_preauthenticated_request" {
    #Required
    access_type = "ObjectRead"
    bucket = var.bucket_name
    name = "worker-image-iso-preauth"
    namespace = data.oci_objectstorage_namespace.ocp_namespace.namespace
    time_expires = "${formatdate("YYYY-MM-DD", timeadd(timestamp(), "24h"))}T00:00:00Z"
    object_name = "coreos-rawdisk.raw"
    depends_on = [ null_resource.worker_image_config ]
    lifecycle {
      ignore_changes = [ time_expires ]
    }
}

## Create worker image from object storage 

resource "oci_core_image" "worker_image" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-worker-image"
  launch_mode    = "PARAVIRTUALIZED"

  image_source_details {
    source_type = "objectStorageUri"
    source_uri  = oci_objectstorage_preauthrequest.ocp_worker_image_preauthenticated_request.full_path

    source_image_type = "QCOW2"
  }
}

resource "oci_core_shape_management" "imaging_compute_shape" {
  compartment_id = var.compartment_ocid
  image_id       = oci_core_image.worker_image.id
  shape_name     = var.compute_shape
}

resource "oci_core_compute_image_capability_schema" "worker_image_capability_schema" {
  compartment_id                                      = var.compartment_ocid
  compute_global_image_capability_schema_version_name = local.global_image_capability_schemas[0].current_version_name
  image_id                                            = oci_core_image.worker_image.id
  schema_data                                         = local.image_schema_data
}


## Create Worker Nodes

resource "oci_core_instance" "worker-01" {
  availability_domain = data.oci_identity_availability_domain.availability_domain.name
  compartment_id      = var.compartment_ocid
  shape = var.compute_shape
  display_name = "worker-01"
  create_vnic_details {
    private_ip          = "10.0.16.103"
    assign_public_ip    = "false"
    assign_private_dns_record = false
    nsg_ids = [
      oci_core_network_security_group.cluster_compute_nsg.id,
    ]
    subnet_id = oci_core_subnet.private.id
  }      
  defined_tags = {
    "openshift-${var.cluster_name}.instance-role" = "compute"
  }
  shape_config {
    memory_in_gbs = var.compute_memory
    ocpus         = var.compute_ocpu
  }
  source_details {
    boot_volume_size_in_gbs = var.compute_boot_size
    boot_volume_vpus_per_gb = var.compute_boot_volume_vpus_per_gb
    source_id                = oci_core_image.worker_image.id
    source_type             = "image"
  }

}

resource "oci_core_instance" "worker-02" {
  availability_domain = data.oci_identity_availability_domain.availability_domain.name
  compartment_id      = var.compartment_ocid
  shape = var.compute_shape
  display_name = "worker-02"
  create_vnic_details {
    private_ip          = "10.0.16.104"
    assign_public_ip    = "false"
    assign_private_dns_record = false
    nsg_ids = [
      oci_core_network_security_group.cluster_compute_nsg.id,
    ]
    subnet_id = oci_core_subnet.private.id
  }      
  defined_tags = {
    "openshift-${var.cluster_name}.instance-role" = "compute"
  }
  shape_config {
    memory_in_gbs = var.compute_memory
    ocpus         = var.compute_ocpu
  }
  source_details {
    boot_volume_size_in_gbs = var.compute_boot_size
    boot_volume_vpus_per_gb = var.compute_boot_volume_vpus_per_gb
    source_id                = oci_core_image.worker_image.id
    source_type             = "image"
  }

}

## Aprove CSRs for worker nodse to join cluster

resource "null_resource" "approve-csr-workers" {
  connection {
    type  =  "ssh"
    user  =  "opc"
    host  =  module.webserver.webserver_public_ip
    private_key = data.local_file.webserver_pem_key.content
  }
  provisioner "remote-exec" {
    inline = [
      "sleep 600",
      "oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{\"\\n\"}}{{end}}{{end}}' | xargs --no-run-if-empty oc adm certificate approve",
      "sleep 60",
      "oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{\"\\n\"}}{{end}}{{end}}' | xargs --no-run-if-empty oc adm certificate approve"
    ]
  }
  depends_on = [ oci_core_instance.worker-01, oci_core_instance.worker-02, null_resource.ansible_vars, data.local_file.webserver_pem_key ]
}

## Remove worker role from master nodes and redeploy pods on workers.

resource "null_resource" "update-node-roles" {
  connection {
    type  =  "ssh"
    user  =  "opc"
    host  =  module.webserver.webserver_public_ip
    private_key = data.local_file.webserver_pem_key.content
  }
  provisioner "remote-exec" {
    inline = [
      "oc patch scheduler cluster --type merge -p '{\"spec\":{\"mastersSchedulable\":false}}'",
      "sleep 10",
      "oc rollout -n openshift-ingress restart deployment/router-default",
      "oc rollout -n openshift-monitoring restart statefulset/alertmanager-main",
      "oc rollout -n openshift-monitoring restart statefulset/prometheus-k8s",
      "oc rollout -n openshift-monitoring restart deployment/grafana",
      "oc rollout -n openshift-monitoring restart deployment/kube-state-metrics",
      "oc rollout -n openshift-monitoring restart deployment/telemeter-client",
      "oc rollout -n openshift-monitoring restart deployment/thanos-querier",
      "echo 'kubeconfig'",
      "cat ~/${var.cluster_name}/auth/kubeconfig",
      "echo 'kube admin password'",
      "cat ~/${var.cluster_name}/auth/kubeadmin",
      "echo 'cluster dashboard url: https://console-openshift-console.apps.${var.cluster_name}.${var.zone_dns}'"
    ]
  }
  depends_on = [ null_resource.ansible_vars, data.local_file.webserver_pem_key, null_resource.approve-csr-workers ]
}

### Outputs for oci manifests

output "webserver_public_ip" {
  value = module.webserver.webserver_public_ip
}

# output "oci_ccm_config" {
#   value = <<OCICCMCONFIG
# Cluster Dahsboard URL:  https://console-openshift-console.apps.${var.cluster_name}.${var.zone_dns}
# compartment: ${var.compartment_ocid}
# vcn: ${oci_core_vcn.openshift_vcn.id}
# loadBalancer:
#   subnet1: ${var.enable_private_dns ? oci_core_subnet.private.id : oci_core_subnet.public.id}
#   securityListManagementMode: Frontend
#   securityLists:
#     ${var.enable_private_dns ? oci_core_subnet.private.id : oci_core_subnet.public.id}: ${var.enable_private_dns ? oci_core_security_list.private.id : oci_core_security_list.public.id}
# rateLimiter:
#   rateLimitQPSRead: 20.0
#   rateLimitBucketRead: 5
#   rateLimitQPSWrite: 20.0
#   rateLimitBucketWrite: 5
#   OCICCMCONFIG
# }
