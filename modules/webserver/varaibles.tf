
variable "webserver_availability_domain" {
    type = string
    description = "availability domain of webserver instance"
}

variable "webserver_compartment_ocid" {
    type = string
    description = "compartment id of webserver instance"
}

variable "webserver_shape" {
    type = string
    description = "shape of webserver instance"
    default = "VM.Standard.E5.Flex"
}

variable "webserver_display_name" {
    type = string
    description = "display name of webserver instance"
    default = "webserver"
}

variable "webserver_private_ip" {
    type = string
    description = "static private IP for webserver"
}

variable "webserver_assign_public_ip" {
    type = bool
    description = "Boolean to assign a public IP for webserver"
}

variable "webserver_subnet_id" {
    type = string
    description = "subnet id of webserver instance"
}

variable "webserver_memory_in_gbs" {
    type = number
    description = "Memory size of webserver instance"
    default = 8
}

variable "webserver_ocpus" {
    type = number
    description = "Number of ocpus for webserver instance"
    default = 2
}

variable "webserver_image_source_id" {
    type = string
    description = "source_id of image to use for webserver instance, default is an OEL 9 instance"
    default = "ocid1.image.oc1.us-sanjose-1.aaaaaaaawh277nw64u75z2eue7mog2oqwh7jjezfyb74ugx2m6f6lxskhcza"
}

variable "webserver_source_type" {
    type = string
    description = "image source type for webserver instance"
    default = "image"
}

variable "webserver_metadata" {
    type = map(string)
    description = "metadata for instance, ex: add an ssh key"
}

