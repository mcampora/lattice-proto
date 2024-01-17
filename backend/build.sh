npm init -y
docker build -t backend:local . 
docker build --platform linux/amd64 --tag backend .
# docker run -rm -it -p 3000:3000 backend:local