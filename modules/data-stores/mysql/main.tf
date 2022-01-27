resource "aws_db_instance" "db_instance" {
    skip_final_snapshot = true
    apply_immediately   = true
    identifier_prefix   = var.db_prefix
    engine              = "mysql"
    allocated_storage   = 10
    instance_class      = "db.t2.micro"
    name                = var.db_name
    username            = "admin"
    password            = var.db_password
}