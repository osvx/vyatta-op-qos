#!/usr/bin/perl
#
# Module: show-input-policy.pl
#
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007 Vyatta, Inc.
# All Rights Reserved.
#
# Author: Stephen Hemminger
# Date: July 2008
# Description: Script to display QoS information in pretty form
#
# **** End License ****
#

use strict;
use warnings;

use Getopt::Long;

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Interface;
use Vyatta::Misc;

my $INGRESS = 0xffff;

sub ingress_interface {
    my @interfaces;

    # Read base qdisc list to find ingress
    open( my $tc, '-|', '/sbin/tc qdisc ls' )
	or die 'tc qdisc command failed';

    while (<$tc>) {
        chomp;
	# qdisc ingress ffff: dev eth0 parent ffff:fff1 -------------------
	my (undef, $qdisc, undef, undef, $dev) = split;
	next unless ($qdisc eq 'ingress');
	push @interfaces, $dev;
    }
    close $tc;

    return @interfaces;
}

sub qminor {
    my $id = shift;

    return hex($1) if ( $id =~ /:(.*)$/ );
}

sub get_filter {
    my ($interface) = @_;

    open( my $tc, '-|',
	  "/sbin/tc -s -s filter show dev $interface parent ffff:" )
      or die 'tc filter command failed: $!';

    my $id = $INGRESS;
    my ($rate, $policy);
    my %filters;

    while (<$tc>) {
	chomp;
	/^filter/ && do {
	    # filter protocol all pref 20 u32
	    # filter protocol all pref 20 u32 fh 800: ht divisor 1
	    # filter protocol all pref 20 u32 fh 800::800 order 2048 ... flowid ffff:2
	    my @field = split;
	    next unless $#field >= 16 && $field[15] eq 'flowid';
	    $id = qminor($field[16]);
	};
	/^\s+police/ && do {
	    # police 0x3 rate 80000Kbit burst 16Kb
	    (undef, undef, undef, $rate) = split;
            $rate    =~ s/bit$//;
	    $policy = 'limit';
	};
	/^\s+action/ && do {
	    # 	action order 1: mirred (Egress Redirect to device ifb0) stolen
	    my (undef, undef, undef, undef, undef, $action)  = split;
	    $policy = lc($action);
	};
        /^\s+Sent/ && do {
            #  Sent 960 bytes 88 pkts (dropped 0, overlimits 0)
            my ( undef, $sent, undef, undef, undef, undef,
		 $drop, undef, $over ) = split;

            $drop =~ s/,$//;
	    $over =~ s/\)$//;

            $filters{$id} = [ $policy, $sent, $drop, $over, $rate, ];
	    $id = $INGRESS;
	    $policy = undef;
	    $rate = undef;
        };
    }

    return \%filters;
}

sub show {
    my $interface = shift;
    my $filters = get_filter($interface);
    return unless $filters;

    print "\n$interface input:\n";

    my $fmt     = "%-10s %-10s %-10s %-9s %-9s %s\n";
    printf $fmt, 'Class', 'Policy', 'Received', 'Dropped', 'Overlimit', 'Rate';

    foreach my $id (sort keys %{$filters}) {
	my @args = @{$filters->{$id}};
	my $class = ($id eq $INGRESS) ? 'default' : $id;
	my $rate = pop @args;
	$rate = '-' unless defined($rate);

	printf $fmt, $class, @args, $rate;
    }
}

sub show_brief {
    my @interfaces = ingress_interface();

    my $fmt     = "%-10s %-10s %-10s %-9s %-9s\n";
    printf $fmt, 'Interface', 'Policy', 'Received', 'Dropped', 'Overlimit';

    foreach my $intf (sort @interfaces) {
	my $filters = get_filter($intf);
	my $policy;
	my $receive = 0;
	my $dropped = 0;
	my $overlimit = 0;

	foreach my $id (keys %{$filters}) {
	    my @args = @{$filters->{$id}};
	    $policy = $args[0];
	    $receive += $args[1];
	    $dropped += $args[2];
	    $overlimit += $args[3];
	}
	printf $fmt, $intf, $policy, $receive, $dropped, $overlimit;
    }
    exit 0;
}

sub usage {
    print "Usage: $0 [--type={ethernet,serial}] --brief\n";
    print "       $0 interface(s)\n";
    exit 1;
}

my ($intf_type, $brief);

GetOptions(
    'type=s' => \$intf_type,
    'brief'  => \$brief,
) or usage();

show_brief()  if $brief;

if ( $#ARGV == -1 ) {
    foreach my $ifname ( getInterfaces() ) {
        if ($intf_type) {
            my $intf = new Vyatta::Interface($ifname);
            next unless ( $intf && $intf_type eq $intf->type() );
        }
        push @ARGV, $ifname;
    }
}

foreach my $interface ( sort @ARGV ) {
    show($interface);
}
