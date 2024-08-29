terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.38.0"
    }
  }
}

data "local_file" "webserver-setup" {
    filename = "${path.module}/setup-webserver.sh"
}

resource "oci_core_instance" "webserver" {
  availability_domain = var.webserver_availability_domain
  compartment_id      = var.webserver_compartment_ocid
  shape = var.webserver_shape
  display_name = var.webserver_display_name
  create_vnic_details {
    private_ip          = var.webserver_private_ip
    assign_public_ip    = var.webserver_assign_public_ip
    subnet_id = var.webserver_subnet_id
  }      
  shape_config {
    memory_in_gbs = var.webserver_memory_in_gbs
    ocpus         = var.webserver_ocpus
  }
  source_details {
    source_id                = var.webserver_image_source_id
    source_type              = var.webserver_source_type
  }
  metadata = var.webserver_metadata
}

output "webserver_public_ip" {
    value = oci_core_instance.webserver.public_ip
}

output "webserver_private_ip" {
    value = oci_core_instance.webserver.private_ip
}


