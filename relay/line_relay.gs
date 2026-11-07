/**
 * TradingView -> LINE relay (Google Apps Script)
 *
 * LINE Notify was shut down on 31 Mar 2025, and TradingView webhooks cannot add the
 * Authorization header the LINE Messaging API needs. This tiny script sits in between:
 * TradingView POSTs the alert text here, and the script pushes it to your LINE.
 *
 * Setup: see README.md (section "LINE").
 */

// Fill these in (Project Settings > Script properties is safer than hard-coding):
//   LINE_CHANNEL_ACCESS_TOKEN  - from LINE Developers console > Messaging API channel
//   LINE_TO                    - your userId (U...) or a groupId (C...)
//   SHARED_SECRET              - any random word; add ?key=<it> to the webhook URL
function doPost(e) {
  var props = PropertiesService.getScriptProperties();
  var secret = props.getProperty('SHARED_SECRET');
  if (secret && (!e.parameter || e.parameter.key !== secret)) {
    return ContentService.createTextOutput('forbidden');
  }

  var text = (e.postData && e.postData.contents) ? e.postData.contents : 'TradingView alert';
  // If the indicator is set to "Telegram JSON", still accept it and use its text field.
  try {
    var parsed = JSON.parse(text);
    if (parsed && parsed.text) text = parsed.text;
  } catch (err) { /* plain text, keep as-is */ }

  UrlFetchApp.fetch('https://api.line.me/v2/bot/message/push', {
    method: 'post',
    contentType: 'application/json',
    headers: { Authorization: 'Bearer ' + props.getProperty('LINE_CHANNEL_ACCESS_TOKEN') },
    payload: JSON.stringify({
      to: props.getProperty('LINE_TO'),
      messages: [{ type: 'text', text: text.substring(0, 4900) }]
    }),
    muteHttpExceptions: true
  });
  return ContentService.createTextOutput('ok');
}
