package Plugins::RSSNews::Plugin;

# RSS News Browser
# Copyright (c) 2006 Slim Devices, Inc. (www.slimdevices.com)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.
#
# This is a reimplementation of the old RssNews plugin based on
# the Podcast Browser plugin.
#
# $Id$

use strict;

use constant FEEDS_VERSION => 1.0;

use HTML::Entities;
use XML::Simple;

use Plugins::RSSNews::Settings;

use Slim::Buttons::XMLBrowser;
use Slim::Formats::XML;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);

# Default feed list
my @default_feeds = (
	{
		name  => 'BBC News World Edition',
		value => 'http://news.bbc.co.uk/rss/newsonline_world_edition/front_page/rss.xml',
	},
	{
		name  => 'CNET News.com',
		value => 'http://news.com.com/2547-1_3-0-5.xml',
	},
	{
		name  => 'New York Times Home Page',
		value => 'http://www.nytimes.com/services/xml/rss/nyt/HomePage.xml',
	},
	{
		name  => 'RollingStone.com Music News',
		value => 'http://www.rollingstone.com/rssxml/music_news.xml',
	},
	{
		name  => 'Slashdot',
		value => 'http://rss.slashdot.org/Slashdot/slashdot',
	},
	{
		name  => 'Yahoo! News: Business',
		value => 'http://rss.news.yahoo.com/rss/business',
	},
);

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.rssnews',
	'defaultLevel' => 'WARN',
	'description'  => getDisplayName(),
});

my @feeds = ();
my %feed_names; # cache of feed names

# in screensaver mode, number of items to display per channel before switching
my $screensaver_items_per_feed;

# $refresh_sec is the minimum time in seconds between refreshes of the ticker from the RSS.
# Please do not lower this value. It prevents excessive queries to the RSS.
my $refresh_sec = 60 * 60;

# per-client screensaver state information
my $savers = {};

sub initPlugin {
	my $class = shift;

	$log->info("Initializing.");

	Plugins::RSSNews::Settings->new;

	Slim::Buttons::Common::addMode('PLUGIN.RSS', getFunctions(), \&setMode);

	my @feedURLPrefs  = Slim::Utils::Prefs::getArray("plugin_RssNews_feeds");
	my @feedNamePrefs = Slim::Utils::Prefs::getArray("plugin_RssNews_names");
	my $feedsModified = Slim::Utils::Prefs::get("plugin_RssNews_feeds_modified");
	my $version       = Slim::Utils::Prefs::get("plugin_RssNews_feeds_version");
	
	$screensaver_items_per_feed = Slim::Utils::Prefs::get('plugin_RssNews_items_per_feed');
	if (!defined $screensaver_items_per_feed) {

		$screensaver_items_per_feed = 3;
		Slim::Utils::Prefs::set('plugin_RssNews_items_per_feed', $screensaver_items_per_feed);
	}

	@feeds = ();

#        |requires Client
#        |  |is a Query
#        |  |  |has Tags
#        |  |  |  |Function to call
#        C  Q  T  F
    Slim::Control::Request::addDispatch(['rss', 'items', '_index', '_quantity'],
        [0, 1, 1, \&cliQuery]);

	Slim::Buttons::Common::addSaver(
		'SCREENSAVER.rssnews',
		getScreensaverRssNews(),
		\&setScreensaverRssNewsMode,
		\&leaveScreenSaverRssNews,
		'PLUGIN_RSSNEWS_SCREENSAVER'
	);

	# No prefs set or we've had a version change and they weren't modified, 
	# so we'll use the defaults
	if (scalar(@feedURLPrefs) == 0 ||
		(!$feedsModified && (!$version  || $version != FEEDS_VERSION))) {
		# use defaults
		# set the prefs so the web interface will work.
		revertToDefaults();
	} else {
		# use prefs
		my $i = 0;
		while ($i < scalar(@feedNamePrefs)) {

			push @feeds, {
				name  => $feedNamePrefs[$i],
				value => $feedURLPrefs[$i],
				type  => 'link',
			};
			$i++;
		}
	}

	if ($log->is_debug) {

		$log->debug("RSS Feed Info:");

		for my $feed (@feeds) {

			$log->debug(join(', ', ($feed->{'name'}, $feed->{'value'})));
		}

		$log->debug("");
	}

	# feed_names should reflect current names
	%feed_names = ();

	map { $feed_names{$_->{'value'} } = $_->{'name'}} @feeds;
	
	updateOPMLCache( \@feeds );
}

sub revertToDefaults {
	@feeds = @default_feeds;

	my @urls  = map { $_->{'value'} } @feeds;
	my @names = map { $_->{'name'}  } @feeds;

	Slim::Utils::Prefs::set('plugin_RssNews_feeds', \@urls);
	Slim::Utils::Prefs::set('plugin_RssNews_names', \@names);
	Slim::Utils::Prefs::set('plugin_RssNews_feeds_version', FEEDS_VERSION);

	# feed_names should reflect current names
	%feed_names = ();

	map { $feed_names{$_->{'value'}} = $_->{'name'} } @feeds;
	
	updateOPMLCache( \@feeds );
}

sub getDisplayName {
	return 'PLUGIN_RSSNEWS';
}

sub getFunctions {
	return {};
}

sub setMode {
	my $client = shift;
	my $method = shift;

	if ($method eq 'pop') {
		Slim::Buttons::Common::popMode($client);
		return;
	}

	# use INPUT.Choice to display the list of feeds
	my %params = (
		header => '{PLUGIN_RSSNEWS} {count}',
		listRef => \@feeds,
		modeName => 'RSS Plugin',
		onRight => sub {
			my $client = shift;
			my $item = shift;
			my %params = (
				url     => $item->{'value'},
				title   => $item->{'name'},
				expires => $refresh_sec,
			);
			Slim::Buttons::Common::pushMode($client, 'xmlbrowser', \%params);
		},

		overlayRef => [
			undef,
			Slim::Display::Display::symbol('rightarrow') 
		],
	);

	Slim::Buttons::Common::pushMode($client, 'INPUT.Choice', \%params);
}

sub cliQuery {
	my $request = shift;
	
	$log->info("Begin Function");
	
	# Get OPML list of feeds from cache
	my $cache = Slim::Utils::Cache->new();
	my $opml = $cache->get( 'rss_opml' );
	Slim::Buttons::XMLBrowser::cliQuery('rss', $opml, $request, $refresh_sec);
}


# Update the hashref of RSS feeds for use with the web UI
sub updateOPMLCache {
	my $feeds = shift;
	
	my $outline = [];
	for my $item ( @{$feeds} ) {
		push @{$outline}, {
			'name'  => $item->{'name'},
			'url'   => $item->{'value'},
			'value' => $item->{'value'},
			'type'  => $item->{'type'},
			'items' => [],
		};
	}
	
	my $opml = {
		'title' => string('PLUGIN_RSSNEWS'),
		'url'   => 'rss_opml',			# Used so XMLBrowser can look this up in cache
		'type'  => 'opml',
		'items' => $outline,
	};
		
	my $cache = Slim::Utils::Cache->new();
	$cache->set( 'rss_opml', $opml, '10days' );
}

sub updateFeedNames {
	my @feedURLPrefs = Slim::Utils::Prefs::getArray("plugin_RssNews_feeds");
	my @feedNamePrefs;

	# verbose debug
	$log->debug("URLs: " . Data::Dump::dump(\@feedURLPrefs));

	# case 1: we're reverting to default
	if (scalar(@feedURLPrefs) == 0) {
		revertToDefaults();
	} else {
		# case 2: url list edited

		my $i = 0;
		while ($i < scalar(@feedURLPrefs)) {

			my $url = $feedURLPrefs[$i];
			my $name = $feed_names{$url};

			if ($name && $name !~ /^http\:/) {

				# no change
				$feedNamePrefs[$i] = $name;

			} elsif ($url =~ /^http\:/) {

				# does a synchronous get
				# XXX: This should use async instead, but not a very high priority 
				# as this code is not used very much
				my $xml = Slim::Formats::XML->getFeedSync($url);

				if ($xml && exists $xml->{'channel'}->{'title'}) {

					# here for podcasts and RSS
					$feedNamePrefs[$i] = Slim::Formats::XML::unescapeAndTrim($xml->{'channel'}->{'title'});

				} elsif ($xml && exists $xml->{'head'}->{'title'}) {

					# here for OPML
					$feedNamePrefs[$i] = Slim::Formats::XML::unescapeAndTrim($xml->{'head'}->{'title'});

				} else {
					# use url as title since we have nothing else
					$feedNamePrefs[$i] = $url;
				}

			} else {
				# use url as title since we have nothing else
				$feedNamePrefs[$i] = $url;
			}

			$i++;
		}

		# if names array contains more than urls, delete the extras
		while ($feedNamePrefs[$i]) {
			delete $feedNamePrefs[$i];
			$i++;
		}

		# save updated names to prefs
		Slim::Utils::Prefs::set('plugin_RssNews_names', \@feedNamePrefs);

		# runtime list must reflect changes
		@feeds = ();
		$i = 0;

		while ($i < scalar(@feedNamePrefs)) {

			push @feeds, {
				name => $feedNamePrefs[$i],
				value => $feedURLPrefs[$i]
			};

			$i++;
		}

		# feed_names should reflect current names
		%feed_names = ();

		map { $feed_names{$_->{'value'}} = $_->{'name'} } @feeds;
		
		updateOPMLCache( \@feeds );
	}
}

################################
# ScreenSaver Mode

sub getScreensaverRssNews {

	return {
		'done' => sub  {
			my ($client, $funct, $functarg) = @_;

			Slim::Buttons::Common::popMode($client);
			$client->update;

			# pass along ir code to new mode if requested
			if (defined $functarg && $functarg eq 'passback') {
				Slim::Hardware::IR::resendButton($client);
			}
		}
	};
}

sub setScreensaverRssNewsMode {
	my $client = shift;

	# init params
	$savers->{$client} = {
		newfeed  => 1,
		line1    => 0,
	};

	$client->lines(\&blankLines);

	# start tickerUpdate in future after updates() caused by server mode change
	Slim::Utils::Timers::setTimer(
		$client, 
		Time::HiRes::time() + 0.5,
		\&tickerUpdate
	);
}

# kill tickerUpdate
sub leaveScreenSaverRssNews {
	my $client = shift;

	Slim::Utils::Timers::killTimers($client, \&tickerUpdate);
	Slim::Utils::Timers::killTimers($client, \&tickerUpdateCheck);

	delete $savers->{$client};
	
	$log->info("Leaving screensaver mode");
}

sub tickerUpdate {
	my $client = shift;

	if ( $savers->{$client}->{newfeed} ) {
		# we need to fetch the next feed
		getNextFeed( $client );
	}
	else {
		tickerUpdateContinue( $client );
	}
}

sub getNextFeed {
	my $client = shift;
	
	# select the next feed and fetch it
	my $index = $savers->{$client}->{feed_index} || 0;
	$index++;
	
	if ( $index > scalar @feeds ) {
		$index = 1;
		# reset error count after looping around to the beginning
		$savers->{$client}->{feed_error} = 0;
	}
	
	$savers->{$client}->{feed_index} = $index;
	
	my $url = $feeds[$index - 1]->{'value'};
	
	$log->info("Fetching next feed: $url");
	
	if ( !$savers->{$client}->{current_feed} ) {
		$client->update( {
			'line' => [ 
				$client->string('PLUGIN_RSSNEWS'),
				$client->string('PLUGIN_RSSNEWS_WAIT')
			],
		} );
	}
	
	Slim::Formats::XML->getFeedAsync( 
		\&gotNextFeed,
		\&gotError,
		{
			'url'     => $url,
			'client'  => $client,
			'expires' => $refresh_sec,
		},
	);
}

sub gotNextFeed {
	my ( $feed, $params ) = @_;
	my $client = $params->{'client'};
	
	# Bug 3860, If the user left screensaver mode while we were fetching the feed, cancel out
	if ( !exists $savers->{$client} ) {
		return;
	}
	
	$savers->{$client}->{current_feed} = $feed;
	
	tickerUpdateContinue( $client );
}

sub gotError {
	my ( $error, $params ) = @_;
	my $client = $params->{'client'};
	
	# Bug 3860, If the user left screensaver mode while we were fetching the feed, cancel out
	if ( !exists $savers->{$client} ) {
		return;
	}
	
	# Bug 1664, skip broken feeds in screensaver mode
	logError("While loading feed: $error, skipping!");
	
	my $errors = $savers->{$client}->{feed_error} || 0;
	$errors++;
	$savers->{$client}->{feed_error} = $errors;
	
	if ( $errors == scalar @feeds ) {

		logError("All feeds failed, giving up!!");
		
		$client->update( {
			'line' => [
				$client->string('PLUGIN_RSSNEWS'),
				$client->string('PLUGIN_RSSNEWS_ERROR')
			],
		} );
	}
	else {	
		getNextFeed( $client );
	}
}

sub tickerUpdateContinue {
	my $client = shift;
	
	# Bug 3860, If the user left screensaver mode, cancel out
	if ( !exists $savers->{$client} ) {
		return;
	}
	
	$savers->{$client}->{line1} = 0;

	# add item to ticker
	$client->update( tickerLines($client) );

	my ($complete, $queue) = $client->scrollTickerTimeLeft();
	my $newfeed = $savers->{$client}->{newfeed};

	# schedule for next item as soon as queue drains if same feed or after ticker completes if new feed
	my $next = $newfeed ? $complete : $queue;

	Slim::Utils::Timers::setTimer(
		$client, 
		Time::HiRes::time() + ( ($next > 1) ? $next : 1),
		\&tickerUpdate
	);
}

# check to see if ticker is empty and schedule immediate ticker update if so
sub tickerUpdateCheck {
	my $client = shift;

	my ($complete, $queue) = $client->scrollTickerTimeLeft();

	if ( $queue == 0 && Slim::Utils::Timers::killTimers($client, \&tickerUpdate) ) {
		tickerUpdate($client);
	}
}

# lines when called by server - e.g. on screensaver start or change of font size
# add undef line2 item to ticker, schedule tickerUpdate to add to ticker if necessary
sub blankLines {
	my $client = shift;

	my $parts = {
		'line'   => [ $savers->{$client}->{line1} || '' ],
		'ticker' => [],
	};

	# check after the update calling this function is complete to see if ticker is empty
	# (to refill ticker on font size change as this clears current ticker)
	Slim::Utils::Timers::killTimers( $client, \&tickerUpdateCheck );	
	Slim::Utils::Timers::setTimer(
		$client, 
		Time::HiRes::time() + 0.1,
		\&tickerUpdateCheck
	);

	return $parts;
}

# lines for tickerUpdate to add to ticker
sub tickerLines {
	my $client = shift;

	my $parts         = {};
	my $new_feed_next = 0; # use new feed next call

	# the current RSS feed
	my $feed = $savers->{$client}->{current_feed};

	assert( ref $feed eq 'HASH', "current rss feed not set\n");

	# the current item within each feed.
	my $current_items = $savers->{$client}->{current_items};

	if ( !defined $current_items ) {

		$current_items = {
			$feed => {
				'next_item'  => 0,
				'first_item' => 0,
			},
		};

	}
	elsif ( !defined $current_items->{$feed} ) {

		$current_items->{$feed} = {
			'next_item'  => 0,
			'first_item' => 0
		};
	}
	
	# add item to ticker or display error and wait for tickerUpdate to retrieve news
	if ( defined $feed ) {
	
		my $line1 = Slim::Formats::XML::unescapeAndTrim( $feed->{'title'} );
		my $i     = $current_items->{$feed}->{'next_item'};
		
		my $title       = $feed->{'items'}->[$i]->{'title'};
		my $description = $feed->{'items'}->[$i]->{'description'} || '';

		# How to display items shown by screen saver.
		# %1\$s is item 'number'	XXX: number not used?
		# %2\$s is item title
		# %3\%s is item description
		my $screensaver_item_format = "%2\$s -- %3\$s";
		
		# we need to limit the number of characters we add to the ticker, 
		# because the server could crash rendering on pre-SqueezeboxG displays.
		my $screensaver_chars_per_item = 1024;
		
		my $line2 = sprintf(
			$screensaver_item_format,
			$i + 1,
			Slim::Formats::XML::unescapeAndTrim($title),
			Slim::Formats::XML::unescapeAndTrim($description)
		);

		if ( length $line2 > $screensaver_chars_per_item ) {

			$line2 = substr $line2, 0, $screensaver_chars_per_item;

			$log->debug("Screensaver character limit exceeded - truncating.");
		}

		$current_items->{$feed}->{'next_item'} = $i + 1;

		if ( !exists( $feed->{'items'}->[ $current_items->{$feed}->{'next_item'} ] ) ) {

			$current_items->{$feed}->{'next_item'}  = 0;
			$current_items->{$feed}->{'first_item'} -= ($i + 1);

			if ( $screensaver_items_per_feed >= ($i + 1) ) {

				$new_feed_next = 1;

				$current_items->{$feed}->{'first_item'} = 0;
			}
		}

		if ( ($current_items->{$feed}->{'next_item'} - 
		      $current_items->{$feed}->{'first_item'}) >= $screensaver_items_per_feed ) {

			# displayed $screensaver_items_per_feed of this feed, move on to next saving position
			$new_feed_next = 1;
			$current_items->{$feed}->{'first_item'} = $current_items->{$feed}->{'next_item'};
		}

		$parts = {
			'line'   => [ $line1 ],
			'ticker' => [ undef, $line2 ],
		};

		$savers->{$client}->{line1} = $line1;
		$savers->{$client}->{current_items} = $current_items;
	}
	else {

		$parts = {
			'line' => [ "RSS News - ". $feed->{'title'}, $client->string('PLUGIN_RSSNEWS_WAIT') ]
		};

		$new_feed_next = 1;
	}

	$savers->{$client}->{newfeed} = $new_feed_next;

	return $parts;
}

1;
