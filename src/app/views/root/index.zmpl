<html>
  <head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <link rel="stylesheet" href="/styles.css" />
  </head>

  <body>
    <div class="text-center pt-10 m-auto">
      // If present, renders the `message_param` response data value, add `?message=hello` to the
      // URL to see the output:
      <h2 class="param text-3xl text-[#f7931e]">{.message_param}</h2>

      // Renders `src/app/views/root/_content.zmpl` with the same template data available:
      <div>{^root/content}</div>
    </div>
  </body>
</html>
