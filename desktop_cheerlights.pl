#!/usr/bin/env perl
# -*- cperl -*-
#
# Cheerlights status display
# More info: http://cheerlights.com/
# 
# By Joe Johnston <jjohn@taskboy.com>
#
# MIT License
#
# Copyright (c) [year] [fullname]
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

use strict;
use warnings;

use File::Slurp;
use Getopt::Std;
use JSON;
use LWP::UserAgent;
use Tk;

our $updateFile = "./update.dat";
our $logFile = "./cheerlights_status.log";

main();

exit;

sub main {
    Log("Starting");
    my %opts;
    
    getopts('?hu:', \%opts);
    if ($opts{'?'} || $opts{'h'}) {
        print usage();
        exit;
    }
    
    do_fetch(\%opts);

    $opts{'u'} = 'colorband' unless defined $opts{'u'};

    if ($opts{'u'} eq 'rain') {
        do_waterdrop_UI(\%opts);
    } elsif ($opts{'u'} eq 'colorband') {
        do_colorband_UI(\%opts);
    } else {
        do_colorband_UI(\%opts);
    }
}

sub usage {
    return qq[$0 - display current status of cheerlights

USAGE:

  $0 [OPTIONS]

OPTIONS:

  h - this screen
  u [TYPE] - type of display to show: ['colorband' | 'rain'] 'colorband' is the default

];
}

sub do_colorband_UI {
    my ($opts) = @_;

    Log("Starting colorband UI");
    my $Top = MainWindow->new();
    $Top->geometry("380x100");
    my $message = "Loading...";
    my $background = "#FFFFFF";

    my $Label = $Top->Label(-textvariable => \$message, -pady => 15)->pack();
    my $Frame = $Top->Frame(-borderwidth => 1, -relief => 'groove', -pady => 5
			   )->pack(-fill => 'x');

    my @canvases;
    for my $i (0..9) {
	push @canvases, $Frame->Canvas(-height => 30,
				       -width => $i * 10,
				      );
	$canvases[-1]->pack(-side=>'left', -expand=> 0);
    }

    $Top->Label(-text => " ")->pack; # spacer

    $Top->repeat(3000, sub {
		     my ($colors, $hexes) = getColor();
		     $message = "Latest colors, oldest to newest";
		     $Label->pack;

		     for my $id (0..8) {
			 #Log("Canvas $id has color " . $hexes->[$id]);
			 $canvases[ $id ]->configure(-background => $hexes->[$id]);
			 $canvases[ $id ]->pack(-side=>'left', -expand=>0);
		     }
		 }
		);

    MainLoop();
}


sub do_waterdrop_UI {
    my ($opts) = @_;
    Log("Starting waterdrop UI");
    my $Top = MainWindow->new();
    $Top->geometry("300x300");
    my $Frame = $Top->Frame(-borderwidth => 1, -relief => 'groove', -pady => 5
                        )->pack(-fill => 'x');
    
    my $Canvas = $Frame->Canvas(-width => 300, -height => 300);
    $Canvas->pack();
    
    my @testers;
    my $prev_upper;
    for my $i (0..2) {
        my $lower = 0;
        if ($i > 0) {
            $lower = $prev_upper;
        }
        my $upper = 10 ** $i;
        $prev_upper = $upper;
        push @testers, sub { $_[0] >= $lower && $_[0] < $upper ? $i : undef};
  }
    
    my $get_hexes_index = sub {
        my $int = int(rand() * 70);
        for my $tester (@testers) {
            my $idx = $tester->($int);
            if (defined $idx) {
                return $idx;
            }
        }
        return;
    };
    
    $Top->repeat(1500, sub {
                     my ($colors, $hexes) = getColor();
                     $hexes = [ @$hexes[-3, -2, -1] ];
                     my $hex_idx = $get_hexes_index->();
                     return unless $hexes->[$hex_idx];
                     
                     Log("Selected hex index $hex_idx which is $hexes->[$hex_idx]");
                     
                     my $min_width = 0;
                     my $x1 = int(rand() * (300-$min_width));
                     my $y1 = int(rand() * (300-$min_width));
                     my $x2 = $x1 + int(rand() * 200) + 30;
                     my $y2 = $y1 + int(rand() * 200) + 30;
                     $Canvas->createOval($x1, $y1, $x2, $y2, -fill => $hexes->[$hex_idx]);
                     
                 }

             );

    MainLoop();
}


sub getColor {
    my (@colors, @hexes);

    if (-e $updateFile) {
	eval {
	    my @content = read_file($updateFile);
	    if (@content) {
		for my $line (@content) {
		    chomp($line);
		    my ($color, $hex) = split(/:/, $line, 2);
		    push @colors, $color;
		    push @hexes, $hex;
		}
	    }
	    1;
	} or do {
	    Log("Could not read $updateFile: $@");
	};
    }

    return (\@colors, \@hexes);
}


sub do_fetch {
    my ($opts) = @_;

    $SIG{CHLD} = "IGNORE";
    my $parent_pid = $$;

    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid) {
	return;
    }

    Log("Starting fetch loop");
    while (1) {
	if (!kill(0, $parent_pid)) {
	    Log("Parent '$parent_pid' has gone away.  Exiting.");
	    exit;
	}
	get_cheerlights_feed();
	sleep(5);
    }
}

{
    my $last_etag = "";

    sub get_cheerlights_feed {
	our $feed_url = q[https://thingspeak.com/channels/1417/feed.json];

	my $ua = LWP::UserAgent->new;
	$ua->timeout(3);

	my $response = $ua->get($feed_url);

	if (!$response->is_success) {
	    Log(sprintf("Failed: %s\n", $response->status_line));
	    return;
	}

	my $feed;
	eval {
	    my $etag = $response->header("ETag");
	    if (defined $last_etag && $etag eq $last_etag) {
		die("Feed has not changed\n");
	    }
	    $last_etag = $etag;
	    $feed = JSON::decode_json($response->content);
	} or do {
	    Log("Decode: $@");
	    return;
	};

	unlink $updateFile;
	for my $idx (-9..-1) {
	    my $last = $feed->{feeds}->[$idx];
	    my $message = sprintf("%s:%s\n", $last->{field1}, $last->{field2});
	    Log("writing [$feed->{feeds}->[$idx]->{created_at}] $message");
	    append_file($updateFile, $message);
	}
    }
}


sub Log {
    my $message = sprintf("%s[%d]: %s\n", scalar(localtime()), $$, join(" ", @_));

     if (-e $logFile && -s $logFile > 1_000_000) {
	if (-e "$logFile.1") {
	    unlink "$logFile.1";
	}
	rename $logFile, "$logFile.1";
    }

    append_file($logFile, $message);

}
