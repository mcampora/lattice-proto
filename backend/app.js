const express = require('express');
const app = express();
const port = 3000;

app.get('/', (req, res) => {
  let d = new Date();
  console.log(d, "Backend: GET /");
  res.status(200).send('Backend response!');
});

app.get('/live', (req, res) => {
  res.status(200).send('Alive!');
});

app.listen(port, () => {
  console.log(`Web service listening at http://localhost:${port}`);
});
