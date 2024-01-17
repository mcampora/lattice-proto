FROM node:18.16.0-alpine3.17
RUN apk --no-cache add curl
RUN mkdir -p /opt/app
WORKDIR /opt/app
COPY ./package.json ./package-lock.json .
RUN npm install
COPY ./app.js .
EXPOSE 3000
CMD [ "npm", "start"]