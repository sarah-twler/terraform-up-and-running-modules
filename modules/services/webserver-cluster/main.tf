locals {
    http_port       = 80
    any_port        = 0
    any_protocol    = "-1"
    tcp_protocol    = "tcp"
    all_ips         = ["0.0.0.0/0"]
    # IP address range that includes all possible IP addresses
        # i.e. this security group allows incoming requests on port 8080 from any(!) IP
}

data "aws_vpc" "default_vpc" {
    default = true
}

data "aws_subnet_ids" "default_subnet_ids" {
    vpc_id = data.aws_vpc.default_vpc.id
}

data "terraform_remote_state" "db" {
    backend = "s3"

    config = {
        bucket  = var.db_remote_state_bucket
        key     = var.db_remote_state_key
        region  = "us-east-2"
    }
}

data "template_file" "user_data" {
    template = file("${path.module}/user-data.sh")

    vars = {
        server_port = var.server_port
        db_address  = data.terraform_remote_state.db.outputs.address
        db_port     = data.terraform_remote_state.db.outputs.port
    } 
}

# application load balancer
# alb consist of listener, listener rules & target groups
resource "aws_lb" "alb" {
    name                = "${var.cluster_name}-alb"
    load_balancer_type  = "application"
    subnets             = data.aws_subnet_ids.default_subnet_ids.ids
    security_groups     = [aws_security_group.alb_security_group.id]
}

# alb listener
resource "aws_lb_listener" "http_alb_listener" {
    load_balancer_arn   = aws_lb.alb.arn
    port                = local.http_port
    protocol            = "HTTP"

    # return a simple 404 page by default
    default_action {
      type  = "fixed-response"

      fixed_response {
        content_type    = "text/plain"
        message_body    = "404: page not found"
        status_code     = 404
      }
    }
}

# alb target group
resource "aws_lb_target_group" "alb_asg_target_group" {
    name        = "${var.cluster_name}-alb-trgt-grp"
    port        = var.server_port
    protocol    = "HTTP"
    vpc_id      = data.aws_vpc.default_vpc.id

    health_check {
        path                = "/"
        protocol            = "HTTP"
        matcher             = "200"
        interval            = 15
        timeout             = 3
        healthy_threshold   = 2
        unhealthy_threshold = 2
    }
}

# alb listener rules
resource "aws_lb_listener_rule" "alb_listener_rule" {
    listener_arn    = aws_lb_listener.http_alb_listener.arn
    priority        = 1000

    condition {
        path_pattern {
            values = ["*"]
        }
    }

    action {
        type = "forward"
        target_group_arn = aws_lb_target_group.alb_asg_target_group.arn
    }
}

resource "aws_launch_configuration" "instances" {
    image_id        = "ami-0c55b159cbfafe1f0"
    instance_type   = var.instance_type
    security_groups = [aws_security_group.instance_security_group.id]

    user_data       = data.template_file.user_data.rendered
    
    # required when using a launch configuration with an auto scaling group
    # refer to docsß
    lifecycle {
        create_before_destroy   = true
    }
} 

resource "aws_autoscaling_group" "asg" {
    launch_configuration    = aws_launch_configuration.instances.name
    vpc_zone_identifier     = data.aws_subnet_ids.default_subnet_ids.ids
    target_group_arns       = [aws_lb_target_group.alb_asg_target_group.arn]
    health_check_type       = "ELB"
    desired_capacity        = 2
    
    min_size                = var.min_size
    max_size                = var.max_size

    tag {
      key                   = "Name"
      value                 = "${var.cluster_name}-asg"
      propagate_at_launch   = true
    }
}

resource "aws_security_group" "alb_security_group" {
    name = "${var.cluster_name}-asg-security-group"
}

resource "aws_security_group_rule" "allow_http_inbound" {
    type                = "ingress"
    security_group_id   = aws_security_group.alb_security_group.id

    from_port   = local.http_port
    to_port     = local.http_port
    protocol    = local.tcp_protocol
    cidr_blocks = local.all_ips
}

resource "aws_security_group_rule" "allow_all_outbound" {
    type                = "egress"
    security_group_id   = aws_security_group.alb_security_group.id

    from_port   = local.any_port
    to_port     = local.any_port
    protocol    = local.any_protocol
    cidr_blocks = local.all_ips
}

resource "aws_security_group" "instance_security_group" {
    name    = "${var.cluster_name}-instance-security-group"
}

resource "aws_security_group_rule" "allow_tcp_inbound" {
    type                = "ingress"
    security_group_id   = aws_security_group.instance_security_group.id

    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = local.tcp_protocol
    cidr_blocks = local.all_ips
}