#! /usr/bin/perl
###
#	MassCategoryBot - MediaWiki bot.
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
# absurd_cats.pl - append/replace categories by sysop/rollback requests
#
###

binmode STDOUT, ':utf8';
use utf8;
use strict;

use lib '.';

use MW;
use ProgressBar::Stack;

#
#
#
our $PAGE_CONFIRM = "Участник:Edwardspec TalkBot/Простановка категорий";
our $SUBPAGE_CMDS = "catbot.js";
our $SUMMARY_CLEAR_TASK_NONE = "Робот: и чего вы ожидали?";
our $SUMMARY_CLEAR_TASK_ACCEPTED = "Робот: принял заказы от: ";
our $SUMMARY_CLEAR_TASK_DONE = "Робот: заказы выполнены; совершено правок: ";
our $SUMMARY_REPORT = "Робот: отчёт по заказу на простановку категорий";
our $CONFIRM_OVERWRITE_TEXT = "<!-- Подпишитесь ниже, чтобы запустить бот: * ~~~~ -->\n\n";
our $SUMMARY_CLEAR_SUBPAGE = "Робот: очистка списка команд (задание выполнено)";

our $BOT_IS_ENABLED = 1;

#
#
#
our $mw = MW->new("configabs.pl");
$mw->{ua}->agent('absurd_cats.pl');

my @users =  $mw->get_user_requests(page => $PAGE_CONFIRM, groups => ['sysop', 'rollback']);

#
# Этап 3. Для каждого авторизованного пользователя скачиваем подстраницу $SUBPAGE_CMDS.
#
my %instr = ();
foreach my $user(@users)
{
	my $res = $mw->api({
		action => 'query',
		prop => 'revisions',
		rvprop => "content",
		rvlimit => 1,
		titles => "Участник:" . $user . "/" . $SUBPAGE_CMDS
	}) || die;
	my @revs = $mw->first_page_revisions($res);
	my $text = $revs[0]->{'*'};

	$instr{$user} = $text;
}

#
# Этап 4. Для каждого пользователя парсим содержимое страницы $SUBPAGE_CMDS.
#
my %actions = ();
my %warnings1 = ();
my %warnings2 = ();
my %warnings3 = ();
while(my($user, $text) = each(%instr))
{
	my %todo = ();
	my $current_action;

	my $tasks = 0;
	$warnings1{$user} = "";
	$warnings2{$user} = "";
	$warnings3{$user} = "";

	my @conflicts = ();

	my $cat_prefix = qr/^(Категория|Category):/i;

LINE_LOOP:
	foreach my $line(split /[\n\r]+/, $text)
	{
		next if($line =~ /^\s*$/);

		if($line =~ /:$/) # Строка, завершённая двоеточием - это действие.
		{
			$line =~ s/:$//;

			if($line =~ />/)
			{ # Команда вида "Прежняя категория > Новая категория:"
				my($from, $to) = split /\s*>\s*/, $line;

				$from =~ s/$cat_prefix//;
				$to =~ s/$cat_prefix//;

				$current_action = [ $from, $to ];
			}
			else
			{ # Команда вида "Новая категория:"
				$line =~ s/$cat_prefix//;
				$current_action = $line;
			}

			next;
		}

		next if(!$current_action); # Строки перед первым действием.

		#
		# Это не действие: $line - название страницы, на которую надо подействовать.
		#
		$line =~ tr/_/ /;
		if(exists $todo{$line})
		{
			#
			# Проверить на дубль действия и наличие противоречий.
			#
			foreach my $action(@{$todo{$line}})
			{
				if(ref($action) eq 'ARRAY')
				{
					if(ref($current_action) eq 'ARRAY')
					{
						# Случаи замен A => B, B => C - противоречие.
						# Пока что не разрешаем, а просто игнорируем.
						if(
							($action->[0] eq $current_action->[1]) ||
							($action->[1] eq $current_action->[0])
						){
							$warnings1{$user} .= "$line\n";

#							warn "CONFLICT 1: $line";
							push @conflicts, $line;
							next LINE_LOOP;
						}

						#
						# Случай замены A=>B, A=>C
						#
						if($action->[0] eq $current_action->[0])
						{
							if($action->[1] eq $current_action->[1])
							{
								# warn "DOUBLE ACTION: $line";
							}

							$warnings3{$user} .= "$line\n";
							next LINE_LOOP;
						}
					}
					else
					{
						# Случай +A, A => B - противоречие.
						if($action->[0] eq $current_action)
						{
							$warnings2{$user} .= "$line\n";

#							warn "CONFLICT 2a: $line";
							push @conflicts, $line;
							next LINE_LOOP;
						}
					}
				}
				else
				{
					if(ref($current_action) eq 'ARRAY')
					{
						# Случай +A, A => B - противоречие.
						if($action eq $current_action->[0])
						{
							$warnings2{$user} .= "$line\n";

#							warn "CONFLICT 2b: $line";
							push @conflicts, $line;
							next LINE_LOOP;
						}
					}
					else
					{
						# Случай +A, +A - дубль действия.
						if($action eq $current_action)
						{
#							warn "DOUBLE ACTION: $line";

							next LINE_LOOP;
						}
					}
				}
			}

			push @{$todo{$line}}, $current_action;
		}
		else
		{
			$todo{$line} = [ $current_action ];
		}
		$tasks ++;
	}

	foreach my $page_with_conflict(@conflicts)
	{
		my $cmds = $todo{$page_with_conflict};
		$tasks -= @$cmds;

		delete $todo{$page_with_conflict};
	}

if(0) # %todo dump:
{
	print "----\n$user:\n";
	todo_dump(\%todo);
	print "\n";
	die;
}

	$actions{$user} = \%todo
		if($tasks > 0); # Если страница пустая, то ничего делать не нужно.
}

#
# Этап 5. Стереть содержимое $PAGE_CONFIRM, указав в комментарии к правке, какие заказы приняты.
#
if($BOT_IS_ENABLED)
{
my $something_to_do = (keys %actions) ? 1 : 0;
my $accepted_list = join(" | ", keys %actions);
$accepted_list =~ s/Гоблин \(ирильдий\) Мефодич Цыперштейн-Диканьский/ГиМЦ-Д/;

$mw->edit({
	action => 'edit',
	title => $PAGE_CONFIRM,
	text => ($something_to_do ? "" : $CONFIRM_OVERWRITE_TEXT),
	nocreate => 1,
	summary => ($something_to_do ? $SUMMARY_CLEAR_TASK_ACCEPTED . $accepted_list : $SUMMARY_CLEAR_TASK_NONE)
});
exit(0) if(!$something_to_do);
}

#
# Этап 6. Подготовить и применить изменения из таблицы %actions.
#
binmode STDERR, ':utf8';

my $saved_ok_cnt = 0;
while(my($user, $todo_ref) = each(%actions))
{
	my @targets = keys %$todo_ref;

	#
	# Красиво отображаем прогресс.
	#
	print "$user:\n";
	my $count = @targets;
	my $i = 0;
	init_progress(count => $count);

	#
	# Элементы отчёта.
	#
	my @saved_ok = ();
	my @failed_to_get = ();
	my @failed_to_save = ();

	foreach my $page(@targets)
	{
		update_progress($i ++);

		my $action = $todo_ref->{$page};
		my $summary = make_summary($user, $action);

#		print sprintf('%30s | %s', $page, $summary), "\n";

		my $mw_page = $mw->get_page({ title => $page });
		if(!$mw_page)
		{
			push @failed_to_get, $page;
#			warn "$page: failed to download\n";
			next;
		}
		my $text = $mw_page->{'*'};

		foreach my $a(@$action)
		{
			if(ref($a) eq 'ARRAY')
			{
				my($from, $to) = @$a;
				$text =~ s/\[\[(Category|Категория):$from(|\|[^\]]*?)\]\]/[[Категория:$to$2]]/;
			}
			else
			{
				next if($text =~ /\[\[(Category|Категория):$a(\||\]\])/);

				$text .= "[[Категория:$a]]";
			}
		}

		# Оформление: шаблоны до категорий
		while(($text =~ s/(\[\[(Category|Категория):[^\]]*?\]\])\s*?({{[^\}]*?}})/$3$1/g) > 0) {};

		$text =~ s/(?<=\}\})(?=\[\[(Category|Категория):)/\n\n/g;
		$text =~ s/(?<=\]\])(?=\[\[(Category|Категория):)/\n/g;

		if($text eq $mw_page->{'*'})
		{
#			warn "$page: nothing to do";
		}
		else
		{
			my $edit = {
				action => 'edit',
				title => $page,
				text => $text,
				minor => 1,
				nocreate => 1,
				bot => 1,
				timestamp => $mw_page->{timestamp},
				summary => $summary
			};

if($BOT_IS_ENABLED) {
			if(!$mw->edit($edit))
			{
				push @failed_to_save, $page;
				next;
			}
			sleep(1);
}
			push @saved_ok, $page;
		}
	}

	update_progress($count);
	print "\n";
	$saved_ok_cnt += @saved_ok;


	#
	# Этап 7. Сообщить пользователю, что действие успешно выполнено.
	#
	my $this_user_sign_diff = $MW::SIGN_DIFF->{$user};
	my $report = "== Робот: ваш заказ по категориям ==\nПривет! С удовольствием сообщаю, что [http://absurdopedia.net/?oldid=$this_user_sign_diff&diff=prev ваш запрос] на массовое добавление категорий был обработан. " . list_in_hider("Категории успешно изменены на следующих страницах:", @saved_ok) . list_in_hider("Не удалось загрузить страницы:", @failed_to_get) . list_in_hider("Не удалось сохранить страницы:", @failed_to_save) . list_in_hider("В задании обнаружены конфликты вида +A, A=>B:", split /\n/, $warnings2{$user}) . list_in_hider("В задании обнаружены конфликты вида A=>B, A=>C:", split /\n/, $warnings3{$user}) . list_in_hider("В задании обнаружены конфликты вида A => B, B => C:", split /\n/, $warnings1{$user}) . "С уважением, [[Участник:Edwardspec TalkBot/Бот массовой категоризации|Edwardspec TalkBot]] ~~~~~";

if($BOT_IS_ENABLED) {
	$mw->edit({
		action => 'edit',
		title => "User talk:$user",
		appendtext => "\n$report",
		nocreate => 1,
#		bot => 1,
		summary => $SUMMARY_REPORT
	});
	$mw->edit({
		action => 'edit',
		title => "Участник:" . $user . "/" . $SUBPAGE_CMDS,
		text => "",
		nocreate => 1,
		bot => 1,
		summary => $SUMMARY_CLEAR_SUBPAGE
	});
}
}

#
# Этап 8. Сделать символическую правку в $PAGE_CONFIRM, указав в комментарии к правке, сколько правок сделано.
#
if($BOT_IS_ENABLED)
{
$mw->edit({
	action => 'edit',
	title => $PAGE_CONFIRM,
	text => $CONFIRM_OVERWRITE_TEXT,
	nocreate => 1,
	summary => $SUMMARY_CLEAR_TASK_DONE . $saved_ok_cnt
});
}

sub list_in_hider
{
	my($header, @list) = @_;
	return "" unless(@list);

	my $ret = "{{hider|hidden=1|title=$header|content={{список через точку";

	foreach my $page(@list)
	{
		$page = ":$page" if($page =~ /^(Файл|Категория):/);
		$ret .= "| [[$page]]";
	}
	$ret .= "}}}} ";

	return $ret;
}

sub todo_dump # for debugging
{
	my $todo_ref = shift;
	foreach my $key(keys %$todo_ref)
	{
		print "$key:\n";
		foreach my $action(@{$todo_ref->{$key}})
		{
			print "\t";
			if(ref($action) eq 'ARRAY')
			{
				print "- " . $action->[0] . ", + " . $action->[1];
			}
			else
			{
				print "+ $action";
			}
			print "\n";
		}
	}
}

sub make_summary
{
	my($user, $actions) = @_;
	$user =~ tr/_/ /;
	if($user eq "Гоблин (ирильдий) Мефодич Цыперштейн-Диканьский")
	{
		$user = "ГиМЦ-Д";
	}
	$user =~ tr/ /_/;
	my $summ = "Робот: по воле $user: ";

	my @summ_tokens = ();
	foreach my $a(@$actions)
	{
		my $append;
		if(ref($a) eq 'ARRAY')
		{
			$append = "[[:Категория:" . $a->[0] . "]] => [[:Категория:" . $a->[1] . "]]";
		}
		else
		{
			$append = "+ [[:Категория:$a]]";
		}
		push @summ_tokens, $append;
	}

	my $summ_res;
	while($#summ_tokens >= 0)
	{
		$summ_res = $summ . join(", ", @summ_tokens);
		last if(length($summ_res) <= 200);

		#
		# Строка описания длиннее 200 символов.
		#
		pop @summ_tokens;
		last if(!$#summ_tokens);

		$summ_tokens[$#summ_tokens] .= "…";
	}
	$summ_res .= "химичим с супердлинными категориями."
		if($summ_res eq $summ);

	return $summ_res;
}
