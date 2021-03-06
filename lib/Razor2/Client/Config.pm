#!/usr/bin/perl -s
##
## Razor2::Client:Config
##
## Copyright (c) 2002, Vipul Ved Prakash.  All rights reserved.
## This code is free software; you can redistribute it and/or modify
## it under the same terms as Perl itself.
##
## $Id: Config.pm,v 1.66 2007/05/10 20:32:10 rsoderberg Exp $

package Razor2::Client::Config;
use strict;
use Data::Dumper;
use File::Copy;
use File::Spec;

use Razor2::Logger;

#use base qw(Razor2::Logger);

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

#
# figures out razorhome and razorconf file
#
sub read_conf {
    my ( $self, $params ) = @_;

    my $default_conf_fn = "$self->{global_razorhome}/razor-agent.conf";
    my $conf;
    my $defaults    = $self->default_agent_conf();
    my $use_engines = $defaults->{use_engines};

    if ( $self->{razorconf} ) {
        #
        # cmd-line config file specified
        #
        $conf = $self->read_file( $self->{razorconf}, $defaults )
          unless ( $self->{opt}->{create} && $self->{opt}->{config} );
        if ( $self->{opt}->{razorhome} ) {
            $self->{computed_razorhome} = $self->{razorhome} = $self->{opt}->{razorhome};
        }
        else {
            $self->find_home( $self->{opt}->{razorhome} || $conf->{razorhome} );
        }
    }
    else {

        $self->compute_razorconf();

        if ( $self->{razorconf} ) {
            $conf = $self->read_file( $self->{razorconf}, $defaults );
        }
        else {
            $self->log( 6, "No razor-agent.conf found, using defaults. " );
            $conf = $defaults;
        }
    }

    foreach ( keys %{$defaults} ) {
        next if exists $conf->{$_};
        $conf->{$_} = $defaults->{$_};
    }

    # Override use_engines from defaults. To store use_engines
    # in the config file is a design flaw, since the client
    # supported engines are defined by the razor-agents source,
    # and could potentially be incorrect in the config file
    # after an upgrade.

    $conf->{use_engines} = $use_engines;

    foreach ( keys %{ $self->{opt} } ) {
        next if ( $_ eq '' || $_ eq 'use_engines' || $_ eq 'razorzone' );
        $conf->{$_} = $self->{opt}->{$_};
    }

    if ($params) {
        foreach ( keys %$params ) {
            next if ( $_ eq '' || $_ eq 'use_engines' || $_ eq 'razorzone' );
            $conf->{$_} = $params->{$_};
        }
    }

    $self->{conf} = $conf;

    #
    # post config processing
    # insert things that should not be in conf here
    #

    # turn off run-time warnings unless debug flag passed
    # http://www.perldoc.com/perl5.6.1/pod/perllexwarn.html
    $^W = 0 unless $conf->{debug};

    # add full path to all config values that need them
    #
    if ( $self->{razorhome} ) {
        foreach (
            qw( logfile pidfile listfile_catalogue listfile_nomination
            listfile_discovery whitelist identity)
          ) {
            next unless $conf->{$_};
            next if $conf->{$_} =~ /^\//;
            next if ( $_ eq 'logfile' && ( $conf->{$_} eq 'syslog' || $conf->{$_} eq 'sys-syslog' || $conf->{$_} eq 'none' ) );
            $conf->{$_} = "$self->{razorhome}/$conf->{$_}";
        }
    }
    return $self->{conf};
}

#
#  Figure out which conf to use - user's own, or system conf.
#
#  If no user conf or no system conf, razorconf will be blank
#  but computed_razorconf will be set.
#
#  However, if razorhome is still unknown, computed_razorconf can be blank
#
sub compute_razorconf {
    my $self = shift;

    my $default_conf_fn = "$self->{global_razorhome}/razor-agent.conf";

    $self->{razorconf} = "";
    $self->find_home();
    if ( $self->{razorhome} ) {
        my $mycf = "$self->{razorhome}/razor-agent.conf";
        $self->{computed_razorconf} = $mycf;
        if ( -r $mycf ) {
            $self->{razorconf} = $mycf;
        }
        elsif ( -e $mycf ) {
            $self->log( 5, "Found but can't read $mycf, skipping." );
        }
        else {
            $self->log( 5, "No $mycf found, skipping." );
        }
    }
    if ( !$self->{razorconf} && -e $default_conf_fn ) {
        if ( -r $default_conf_fn ) {
            $self->{razorconf} = $default_conf_fn;
        }
        else {
            $self->log( 5, "Found but can't read $default_conf_fn, skipping." );
            $self->{computed_razorconf} ||= $default_conf_fn;
        }
    }
}

sub write_conf {
    my ( $self, $hash ) = @_;

    unless ( $self->{razorconf} ) {
        $self->log( 5, "Cannot write_conf without razorconf set" );
        return $self->error("Cannot write_conf without razorconf set");
    }
    my $now = localtime();
    my $srcmsg;
    unless ($hash) {
        $hash = $self->default_agent_conf();
        if ( -r $self->{razorconf} ) {
            $hash = $self->read_file( $self->{razorconf}, $hash );
            $srcmsg = "Non-default values taken from $self->{razorconf}";
        }
        else {
            $srcmsg = "Created with all default values";
        }
    }

    my $clientheader = <<EOFCLIENT;
#
# Razor2 config file
# 
# Autogenerated by $self->{name_version} 
# $now
# $srcmsg 
# 
# see razor-agent.conf(5) man page 
#
EOFCLIENT
    return $self->write_file( $self->{razorconf}, $hash, 0, $clientheader );
}

sub find_user {
    my $self = shift;

    return 1 if $self->{user};

    $self->{user} = getpwuid($>) || do {
        $self->log( 1, "Can't figure out who the effective user is: $!" );
        return undef;
    };
    return 1;
}

# compute razorhome.  like so:
#
#    -home=/tmp/razor/              used if readable, else
#    'razorhome' from config file   used if readable, else
#    <home>/.razor/                 used if readable, else
#    <home>/.razor/                 is created.  if that fails, no razorhome.
#    -conf=/foo/razor/razor.conf    if all else fails pick it up from the config file path,
#                                   if one is available

sub find_home {
    my ( $self, $rhome ) = @_;

    my $dotrazor = '.razor';
    $dotrazor = '_razor' if $^O eq 'VMS';

    if ( defined $self->{razorhome} ) {
        $self->{razorhome_computed} = $self->{razorhome};
        return 1;
    }

    if ( defined $self->{opt}->{razorhome} ) {
        $self->{razorhome_computed} = $self->{razorhome};
        return 1;
    }

    # if razorhome is read from config file, its passed as rhome
    unless ($rhome) {

        if ( defined $ENV{HOME} ) {
            $rhome = File::Spec->catdir( "$ENV{HOME}", "$dotrazor" );
        }
        else {
            return unless $self->find_user();
            $rhome = File::Spec->catdir( ( getpwnam( $self->{user} ) )[7], "$dotrazor" ) || "/home/$self->{user}/$dotrazor";
        }
        $rhome = VMS::Filespec::unixify($rhome) if $^O eq 'VMS';
        $self->log( 8, "Computed razorhome from env: $rhome" );
    }
    $self->{razorhome_computed} = $rhome;

    if ( -d $rhome ) {
        if ( -w $rhome ) {
            $self->log( 6, "Found razorhome: $rhome" );
        }
        else {
            $self->log( 6, "Found razorhome: $rhome, however, can't write to it." );
        }
        $self->{razorhome} = $rhome;
        return 1;

    }

    if ( $self->{razorconf} ) {
        my $path = $$self{razorconf};
        if ( $path =~ m:/: ) {
            if ( $path =~ m:(.*)/: ) {
                $self->{razorhome} = $1;
                return 1;
            }
        }
    }

    $self->log( 5, "No razorhome found, using all defaults" );
    $self->{razorhome} = "";
    return 1;
}

sub create_home {
    my ( $self, $rhome ) = @_;

    if ( -d $rhome ) {
        $self->{razorhome} = $rhome;
        return 1;
    }
    if ( mkdir $rhome, 0755 ) {
        $self->log( 6, "Created razorhome: $rhome" );
        $self->{razorhome} = $rhome;
        return 1;
    }
    return $self->error("Could not mkdir $rhome: $!");
}

sub compute_identity {
    my ($self) = @_;
    $self->find_home() or return;

    return 1 if $self->{identity};

    my $id;

    if ( $id = $self->{opt}->{identity} ) {
        $self->{identity} = $self->my_readlink($id);

        # warn we can't read it unless we are registering new identity
        $self->log( 6, "Can't read identity:  $self->{identity}" )
          unless ( $self->{opt}->{register} ) || ( -r $self->{identity} );
        return 1;

        # if not specified via cmd-line, just compute it, don't read it.

    }
    elsif ( $id = $self->{conf}->{identity} ) {
        $self->{identity} = $self->my_readlink($id);
        return 1;

    }
    else {
        $id = $self->{razorhome} ? "$self->{razorhome}/identity" : "";
        $self->{identity} = $self->my_readlink($id);
        return 1;
    }
}

sub get_ident {
    my ($self) = @_;
    $self->find_home() or return;

    my $idfn = $self->{identity};
    return $self->error("Cannot read the identity file: $idfn") unless -r $idfn;

    $idfn = $self->my_readlink($idfn);

    my $mode = ( ( stat($idfn) )[2] ) & 07777;    # mask off file type
    if ( $mode & 0007 ) {
        $self->log( 2, "Please chmod $idfn so it is not world readable." );
    }
    return $self->read_file($idfn);
}

# returns { user => $user, pass => $pass } if success
# returns 2 if error
sub register_identity {
    my ( $self, $user, $pass ) = @_;
    my $ident = $self->register(
        {
            user => $user,
            pass => $pass,
        }
    );
    $self->disconnect() or return 2;
    return $ident || 2;
}

sub ident_fn {
    my ( $self, $ident ) = @_;
    $self->find_home() or return;

    my $orig;
    my $syml;
    my $obase = "identity-$ident->{user}";

    $obase = $1 if $obase =~ /^(\S+)$/;    # untaint obase

    # if it's a user specified identity file, don't symlink
    unless ( $orig = $self->{opt}->{identity} ) {
        $orig = "$self->{razorhome}/$obase";
        $syml = "$self->{razorhome}/identity";

        $orig = $1 if $orig =~ /^(\S+)$/;    # untaint orig
        $syml = $1 if $syml =~ /^(\S+)$/;    # untaint syml
    }

    return ( $orig, $obase, $syml );
}

sub save_ident {
    my ( $self, $ident ) = @_;

    my ( $orig, $obase, $syml ) = $self->ident_fn($ident);

    unless ( length $orig ) {
        return $self->error("couldn't figure out identity filename");
    }

    rename( $orig, "$orig.bak" ) if -s $orig;
    my $umask = umask 0077;    # disable group and all from read/write/execute
    $self->write_file( $orig, $ident ) or return;
    umask $umask;

    # don't create a symlink if user specified identity file from cmd-line
    return $orig unless $syml;

    unless ( $self->{opt}->{symlink} ) {
        return $orig if -e $syml;    # already has another identity
    }

    unlink $syml;
    if ( eval { symlink( "", "" ); 1 } ) {
        $obase = $1 if $obase =~ /^(\S+)$/;    # untaint obase
        $syml  = $1 if $syml =~ /^(\S+)$/;     # untaint syml

        symlink $obase, $syml
          or return $self->error("Created $orig, but could not symlink to it $syml: $!");
    }
    else {
        $self->log( 5, "symlinks don't work on this machine" );
        copy( $orig, $syml );
    }
    return $orig;
}

sub my_readlink {
    my ( $self, $fn ) = @_;

    while (1) {
        return $fn unless -l $fn;

        if ( $fn =~ /^(.*)\/([^\/]+)$/ ) {
            my $dir = $1;
            $fn = readlink $fn;
            $fn = $1 if $fn =~ /^(\S+)$/;           # untaint readlink
            $fn = "$dir/$fn" unless $fn =~ /^\//;
        }
        else {
            $fn = readlink $fn;
            $fn = $1 if $fn =~ /^(\S+)$/;           # untaint readlink
        }
    }
}

sub parse_value {
    my ( $self, $value ) = @_;

    $value =~ s/^\s+//;
    $value =~ s/\s+$//;
    if ( $value =~ m:,: ) {
        my @values = split /,\s*/, $value;
        return [@values];
    }
    else {
        return $value;
    }
}

# given filename, returns hash ref of key = val from file
# if $nothash, than no key && val, just return array ref containing all lines.
#
sub read_file {
    my ( $self, $fn, $h, $nothash ) = @_;

    unless ( defined $fn && length $fn ) {
        $self->log( 5, "Filename not provided to read_file" );
        return;
    }

    my $conf = ref($h) eq 'HASH' ? $h : {};

    if ( $^O eq 'VMS' && $fn !~ /\[/ ) {
        my ( $dir, $file, $ext ) = ( $fn =~ /(^.*\/)(.*)(\..*)$/ );
        $dir =~ s/\./_/g;
        $file =~ s/\./_/g;
        $fn = $dir . $file . $ext;
    }

    $fn = $1 if $fn =~ /^(\S+)$/;    # untaint $fn

    unless ( defined($fn) && ( ( $fn =~ /^\// ) || -e $fn ) ) {
        $self->log( 7, "Can't read file $fn, looking relative to $self->{razorhome}" );
        $fn = "$self->{razorhome}/$fn";
        $fn = $1 if $fn =~ /^(\S+)$/;    # untaint $fn
    }

    my $total = 0;
    my @lines;
    unless ( open CONF, "<$fn" ) {
        $self->log( 5, "Can't read file $fn: $!" );
        return;
    }

    # set $/ to the default in case someone has overwritten $/ elsewhere
    local $/ = "\n";

    for (<CONF>) {
        chomp;
        next if /^\s*#/;
        if ($nothash) {
            next unless s/^\s*(.+?)\s*$/$1/;    # untaint
            $conf->{$_} = 7;
            push @lines, $_;
        }
        else {
            next unless /=/;
            my ( $attribute, $value ) = /^\s*(.+?)\s*=\s*(.+?)\s*$/;    # untaint
            next unless ( defined $attribute && defined $value );
            $conf->{$attribute} = $self->parse_value($value);
        }
        $total++;
    }
    close CONF;
    $self->log( 5, "read_file: $total items read from $fn" );

    return $nothash ? \@lines : $conf;
}

# given hash ref, writes to file key = val
# NOTE: key should not contain '=';
#
# given array ref, writes to file each item
#
# given scalar ref, writes to file
#
sub write_file {
    my ( $self, $fn, $hash, $append, $header, $lock ) = @_;

    $fn = "$self->{razorhome}/$fn" unless ( $fn =~ /^\// );
    $fn = ">$fn" if $append;

    if ( $^O eq 'VMS' && $fn !~ /\[/ ) {
        my ( $dir, $file, $ext ) = ( $fn =~ /(^.*\/)(.*)(\..*)$/ );
        $dir =~ s/\./_/g;
        $file =~ s/\./_/g;
        $fn = $dir . $file . $ext;
    }

    $fn = $1 if $fn =~ /^(\S+)$/;    # untaint $fn

    # check for lock file
    my $lockfile = "$fn.lock";
    $lockfile = "${fn}_lock;1" if $^O eq 'VMS';
    if ($lock) {
        if ( -r "$lockfile" ) {
            return $self->error("File is locked, try again later: $lockfile");
        }
        else {
            unless ( open LOCK, ">$fn.lock" ) {
                return $self->error("Can't create lock file $fn.lock: $!");
            }
            close LOCK;
        }
    }
    unless ( open CONF, ">$fn" ) {
        return $self->error("Can't write file $fn: $!");
    }
    print CONF "$header\n" if $header;
    my $total = 0;
    if ( ref($hash) eq 'HASH' ) {
        foreach ( sort keys %$hash ) {
            return $self->error("Key cannot contain '=': $_") if /=/;
            printf CONF "%-22s = ", $_;
            if ( ref( $hash->{$_} ) eq "ARRAY" ) {
                print CONF join( ',', @{ $hash->{$_} } ) . "\n";
            }
            else {
                print CONF $hash->{$_} . "\n";
            }
            $total++;
        }

    }
    elsif ( ref($hash) eq 'ARRAY' ) {
        foreach (@$hash) {
            next unless /\S/;
            if ( ref($_) eq "ARRAY" ) {
                print CONF join( ', ', @$_ ) . "\n";
            }
            else {
                print CONF $_ . "\n";
            }
            $total++;
        }
    }
    elsif ( ref($hash) eq 'SCALAR' ) {
        printf CONF $$hash;
        $total++;
    }
    close CONF;
    if ($lock) {
        1 while unlink "$lockfile";
    }
    $self->log( 5, "wrote $total " . ref($hash) . " items to file: $fn" );

    #return $total;
    return 1;
}

sub default_server_conf {
    my $self     = shift;
    my $defaults = {
        srl          => -1,
        ep4          => '7542-10',
        bql          => 4,
        ac           => 0,
        bqs          => 128,
        se           => 'C8',                     # engines 4, 8
        dre          => 4,
        zone         => 'razor2.cloudmark.com',
        logic_method => 4,
    };

    # split strings with , into array
    foreach ( keys %$defaults ) {
        $defaults->{$_} = $self->parse_value( $defaults->{$_} );
    }
    return $defaults;
}

sub default_agent_conf {
    my $self = shift;

    #
    # These get overwritten by whatever's in config file,
    # which in turn gets overwritten by cmd-line options.
    #
    my $defaults = {
        debuglevel          => "3",
        logfile             => "razor-agent.log",
        listfile_catalogue  => "servers.catalogue.lst",
        listfile_nomination => "servers.nomination.lst",
        listfile_discovery  => "servers.discovery.lst",
        min_cf              => "ac",
        turn_off_discovery  => "0",
        ignorelist          => "0",
        razordiscovery      => "discovery.razor.cloudmark.com",
        rediscovery_wait    => "172800",
        report_headers      => "1",
        whitelist           => "razor-whitelist",
        use_engines         => "4, 8",
        identity            => "identity",
        logic_method        => 4,
    };

    # 'razorhome' can exist in .conf, but we compute it instead of listing it here
    # 'rlimit' ?

    # split strings with , into array
    foreach ( keys %$defaults ) {
        $defaults->{$_} = $self->parse_value( $defaults->{$_} );
    }
    return $defaults;
}

1;

