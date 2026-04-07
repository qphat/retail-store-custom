# Fetch available AZs in the region dynamically — no hardcoded "us-east-1a"
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Slice to the requested count (e.g. az_count=2 → ["us-east-1a", "us-east-1b"])
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

# ── VPC ──────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true   # required for Cloud Map / service discovery
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.env_name}-vpc" })
}

# ── Public subnets (one per AZ) ───────────────────────────────────────────────
# Public subnets host the ALB. Tasks themselves run in private subnets.
resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.cidr_block, 8, count.index)       # 10.0.0.0/24, 10.0.1.0/24
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, { Name = "${var.env_name}-public-${count.index + 1}" })
}

# ── Private subnets (one per AZ) ─────────────────────────────────────────────
# ECS Fargate tasks run here — not directly reachable from the internet.
resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.cidr_block, 8, count.index + 10)        # 10.0.10.0/24, 10.0.11.0/24
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, { Name = "${var.env_name}-private-${count.index + 1}" })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.env_name}-igw" })
}

# ── NAT Gateway (one, in first public subnet) ─────────────────────────────────
# Private subnets route outbound traffic here so Fargate tasks can pull images.
# Note: LocalStack simulates EIP/NAT but no real routing occurs locally.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.env_name}-nat-eip" })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id   # NAT lives in the first public subnet
  tags          = merge(var.tags, { Name = "${var.env_name}-nat" })

  depends_on = [aws_internet_gateway.main]
}

# ── Route tables ──────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.env_name}-public-rt" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.env_name}-private-rt" })
}

# Associate each subnet with its route table
resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
