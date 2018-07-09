Perl bot of mass categorization for MediaWiki.

FIXME: too much Absurdopedia config is hardcoded, not usable on other wikis.

----

Install required libraries:
`cpan MediaWiki::API ProgressBar::Stack`

Modify login credentials in `configabs.pl` and (for another wiki) configs in `catbot.pl`.

Run the bot:
`perl catbot.pl`

----

NOTE: MediaWiki account of the bot will need 'edituserjs' right.
(because it edits the page [[User:<other-user>/catbot.js]])
