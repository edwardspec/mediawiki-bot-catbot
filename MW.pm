#! /usr/bin/perl
###
#	MW.pm - MediaWiki bot module, extends MediaWiki::API.
#	Copyright (C) 2010 Edward Chernenko.
#
#	This program is free software; you can redistribute it and/or modify
#	it under the terms of the GNU General Public License as published by
#	the Free Software Foundation; either version 3 of the License, or
#	(at your option) any later version.
#
#	This program is distributed in the hope that it will be useful,
#	but WITHOUT ANY WARRANTY; without even the implied warranty of
#	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#	GNU General Public License for more details.
###
#
# MW.pm - wrap MediaWiki::API calls, add several utility functions
#
###

package MW;
require Exporter;
use MediaWiki::API;
use Data::Dumper;
use Date::Parse;
@ISA = qw(Exporter MediaWiki::API);
@EXPORT = qw(new Dumper @MONTHS $USER sign_time_by_timestamp db_time_by_timestamp db_time str2time);

use strict;
use utf8;
push @INC, "/home/edward/TEST/bots";

use vars qw($API $USER $PASS $LOGPAGE);
our @MONTHS = qw(января февраля марта апреля мая июня июля августа сентября октября ноября декабря);

our $SIGN_DIFF = {};
our $BOT_PASSWORD;
1;

BEGIN
{
	use POSIX qw(locale_h);
	use locale;
	setlocale(LC_CTYPE, "ru_RU.utf8");
}

sub new
{
	my($class, $config) = @_;
	require ($config || $main::CONFIG || "bot.cfg");

	$USER =~ tr/ /_/
		if($USER);

	my $mw = MediaWiki::API->new({ api_url => $API, on_error => \&error_handler });
	$mw->login({ lgname => $USER, lgpassword => $PASS }) || $mw->MW::die();

	bless $mw, $class;
	return $mw;
}
sub error_handler
{
	my $mw = shift;
	if($mw->{error} && $mw->{error}->{code})
	{
		$mw->MW::die();
	}
}

sub api # Never encode hashref
{
	my($mw, $query, $options) = @_;
	$options->{skip_encoding} = 1;

	$mw->MediaWiki::API::api($query, $options);
}

sub die
{
	my $mw = shift;
	CORE::die("MediaWiki error: [" . $mw->{error}->{code} . '] ' . $mw->{error}->{details} . "\n");
}

#
# get_user_requests
# Возвращает список пользователей, подписавшихся на определённой странице после последней правки там бота.
# Параметры - хэш-массив с ключами:
#	page - название страницы
#	groups - указатель на массив групп, одна из которых необходима, чтобы учесть пользователя. Например,
#		можно задать groups => ['sysop', 'rollback']. Если параметр не задан, то группы не проверять.
#	blocked_ok - установите в 1, чтобы учесть заблокированных пользователей. По умолчанию их пропускают.
#	limit - предел, сколько правок на странице проверять. Не более 500, для ботов 5000. По умолчанию 100.
#
# ВАЖНО!
# Проверяется только одна (последняя) правка каждого пользователя. Т.е. если участник подписался, а затем
#	поправил запятую на странице, то он не будет засчитан. Подпись должна быть в последней правке.
# Критерий подлинности подписи: дата и время в подписи должны совпадать со временем правки.
#
sub get_user_requests
{
	my($mw, %options) = @_;

	my $page = $options{page};
	my $groups = $options{groups};
	my $blocked_ok = $options{blocked_ok};
	my $limit = $options{limit} || 100;

	my $group_regex = "";
	if($groups)
	{
		for(my $i = 0; $i < @$groups; $i ++)
		{
			$groups->[$i] = quotemeta($groups->[$i]);
		}
		$group_regex = "^(" . join("|", @$groups) . ")\$";
	}
	$group_regex = qr($group_regex);

	#
	# Этап 1. Получаем список пользователей, подписавшихся на странице $PAGE_CONFIRM.
	# Проверка: время в их подписи должно быть равно времени совершения правки.
	#
	my $res = $mw->api({
		action => 'query',
		prop => 'revisions',
		rvprop => "ids|user|timestamp|content",
		rvlimit => $limit,
		titles => $page
	}) || $mw->die();

	my @users = ();
	my %users_checked = ();
	$SIGN_DIFF = {};
	$USER =~ tr/_/ /;
	foreach my $edit($mw->first_page_revisions($res))
	{
		my $user = $edit->{user};
		next if($users_checked{$user}); # Проверять только последнюю правку участника.
		$users_checked{$user} = 1;

		last if($user eq $USER); # Нашли правку бота: запросы в более ранних правках уже обработаны.

		my $text = $edit->{'*'};
		my $time_sign = sign_time_by_timestamp($edit->{timestamp});
		$time_sign = quotemeta($time_sign);

	#	die $time_sign . "\n\n" . $text;
		if($text =~ /$time_sign/)
		{
			push @users, $user;
			$SIGN_DIFF->{$user} = $edit->{revid};
		}
	}

	goto check_done if(!$groups && $blocked_ok);

	#
	# Этап 2. Принимаем к обработке только запросы тех пользователей, которые имеют на это право.
	# Проверка: наличие флага sysop или rollback.
	#
	my @usprop = ();
	push @usprop, "groups" if($groups);
	push @usprop, "blockinfo" if(!$blocked_ok);
	# push @usprop, "editcount";
	$res = $mw->api({
		action => 'query',
		list => 'users',
		usprop => join('|', @usprop),
		ususers => join('|', @users)
	}) || $mw->die();
	my @users_ext = @{$res->{query}->{users}};
	@users = ();
	foreach my $user(@users_ext)
	{
		next if(!$blocked_ok && $user->{blockedby});
		if($groups)
		{
			next if(!$user->{groups});

			my $match = 0;
			foreach my $group(@{$user->{groups}})
			{
				if($group =~ /$group_regex/)
				{
					$match = 1;
					last;
				}
			}
			next if(!$match);
		}

		push @users, $user->{name};
	}

check_done:
	return @users;
}
sub first_page_revisions
{
	my($mw, $res) = @_;
	my($page) = values %{$res->{query}->{pages}};
	return @{$page->{revisions}};
}


# Utility functions
sub sign_time_by_timestamp
{
	my $ts = shift;
	my($sec, $min, $hour, $day, $month, $year) = strptime($ts);
	$year += 1900;

	$day =~ s/^0//;

	return "$hour:$min, $day " . $MONTHS[$month] . " $year (UTC)";
}
sub db_time
{
	my $t = (shift || time());
	my($sec, $min, $hour, $day, $month, $year) = gmtime($t);
	$year += 1900;
	$month ++;
	$month = "0$month" if($month < 10);
	$day = "0$day" if($day < 10);
	$hour = "0$hour" if($hour < 10);
	$min = "0$min" if($min < 10);
	$sec = "0$sec" if($sec < 10);

	return "$year$month$day$hour$min$sec";
}
sub db_time_by_timestamp
{
	my $ts = shift;
	return db_time(str2time($ts));
}
