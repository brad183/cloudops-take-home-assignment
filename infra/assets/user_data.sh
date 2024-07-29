#!/bin/bash
yum update -y
yum install -y epel-release
yum install -y nginx
yum install -y git
git clone https://${github_user}:${github_token}@github.com/${github_repo}.git
cd cloudops-take-home-assignment
git pull -a
git checkout ${github_branch}
yes | cp assets/default.htm /usr/share/nginx/html/index.html
yes | cp assets/logo.jpg /usr/share/nginx/html/
systemctl start nginx
systemctl enable nginx