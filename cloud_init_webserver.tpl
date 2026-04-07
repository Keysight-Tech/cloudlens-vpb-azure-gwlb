#!/bin/bash

# Update package lists
apt update -y

# Install required packages including nginx
apt install -y net-tools tcpdump nginx ca-certificates curl gnupg lsb-release

# Set up Docker repository
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker and dependencies
apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable and start Docker
systemctl enable docker
systemctl start docker

# Enable and start NGINX
systemctl enable nginx
systemctl start nginx

# Create a styled web page
cat <<EOF > /var/www/html/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body {
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            background-color: #f0f0f0;
            font-family: Arial, sans-serif;
            margin: 0;
        }
        .welcome-text {
            font-size: 50px;
            font-weight: bold;
            color: rgb(0, 136, 255);
            text-shadow: 2px 2px 4px rgba(0, 0, 0, 0.2);
        }
    </style>
</head>
<body>
    <div class="welcome-text">Hello, welcome to Keysight, Azure VTap<br>$(hostname)</div>
</body>
</html>
EOF
