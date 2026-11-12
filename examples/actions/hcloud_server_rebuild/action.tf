resource "hcloud_server" "example" {
  name        = "example"
  server_type = "cx22"
  image       = "ubuntu-24.04"
}

action "hcloud_server_rebuild" "example" {
  config {
    server_id = hcloud_server.example.id
    image     = "ubuntu-24.04"
  }
}
