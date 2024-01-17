const express = require('express');
const app = express();
const port = 4000;
const http = require('http');
const BACKEND_URL = process.env.BACKEND_URL || 'http://localhost:3000';

app.get('/', (req, res) => {
  let d = new Date();
  console.log(d, "Frontend: GET /");
  http.get(BACKEND_URL, (resp) => {
    let data = '';

    // A chunk of data has been received.
    resp.on('data', (chunk) => {
      data += chunk;
    });

    // The whole response has been received. Print out the result.
    resp.on('end', () => {
      console.log("Frontend result: " + data);
      res.status(200).send("Frontend: " + data);
    });

  }).on("error", (err) => {
    let msg = "Frontend error: " + err.message;
    console.log(msg);
    res.status(500).send(msg);
  });
});

app.get('/live', (req, res) => {
  res.status(200).send('Alive!');
});

app.listen(port, () => {
  console.log(`Web service listening at http://localhost:${port}`);
});
