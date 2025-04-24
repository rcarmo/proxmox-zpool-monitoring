# Using the Pushover API

## Registration

Register your application, set its name and upload an icon, and get an API token in return (often referred to as `APP_TOKEN` in our documentation and code examples).

## API Endpoint

Send an HTTPS POST request to:

```
https://api.pushover.net/1/messages.json
```

## Parameters

### Required Parameters

* `token` - Your application's API token (required).
* `user` - Your user/group key (or that of your target user), viewable when logged into our dashboard; often referred to as `USER_KEY` in our documentation and code examples (required).
* `message` - Your message (required).

### Optional Parameters

* `attachment` - A binary image attachment to send with the message ([documentation](https://pushover.net/api#attachment)).
* `attachment_base64` - A Base64-encoded image attachment to send with the message ([documentation](https://pushover.net/api#attachment)).
* `attachment_type` - The MIME type of the included `attachment` or `attachment_base64` ([documentation](https://pushover.net/api#attachment)).
* `device` - The name of one of your devices to send just to that device instead of all devices ([documentation](https://pushover.net/api#device)).
* `html` - Set to `1` to enable HTML parsing ([documentation](https://pushover.net/api#html)).
* `priority` - A value of `-2`, `-1`, `0` (default), `1`, or `2` ([documentation](https://pushover.net/api#priority)).
* `sound` - The name of a supported sound to override your default sound choice ([documentation](https://pushover.net/api#sounds)).
* `timestamp` - A Unix timestamp of a time to display instead of when our API received it ([documentation](https://pushover.net/api#timestamp)).
* `title` - Your message's title, otherwise your app's name is used.
* `ttl` - A number of seconds that the message will live, before being deleted automatically ([documentation](https://pushover.net/api#ttl)).
* `url` - A supplementary URL to show with your message ([documentation](https://pushover.net/api#urls)).
* `url_title` - A title for the URL specified as the `url` parameter, otherwise just the URL is shown ([documentation](https://pushover.net/api#urls)).
