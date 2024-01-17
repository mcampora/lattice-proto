npm init -y
docker build -t frontend:local . 
docker build --platform linux/amd64 --tag frontend .
# docker run -rm -it -p 4000:4000 frontend:local