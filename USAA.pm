#!/usr/bin/perl -w
# -*- perl -*-

package Finance::Bank::USAA;

use LWP;
use Data::Dumper;
use XML::LibXML;
use strict;

our $VERSION = '1.3';

# USAA uses cookies:
our $browser = LWP::UserAgent->new();
$browser->cookie_jar({});

# enable to see what's going on:
our $verbose = 0;

# unbuffer output:
$|++;

sub logmsg {
    if ($verbose) {
        my @msg = @_;
        chomp @msg;
        my ($pkg, $fname, $line, $sub) = caller(1);
        printf STDERR "[%50s:%-5d] {%-50s} ", $fname, $line, $sub;
        print STDERR @msg, "\n";
    }
}

sub dopost {
    my $url      = shift;
    my $postdata = shift || [];

    logmsg "getting $url";

    my $resp = $browser->post($url, $postdata);

    logmsg "$resp successful? " . ($resp->is_success ? "yes" : "no") . "\n";
    logmsg Dumper($resp);
    logmsg "$resp successful ? " . $resp->is_success . "\n";
    logmsg $resp->content . "\n";
    
    $resp->content;
}


sub fetch_data {
    my ($class, %opts) = @_;

    $verbose = $opts{verbose} if defined $opts{verbose};
    
    my $url        = 'https://www.lc.usaa.com/inet/lcs_corp/Logon';
    my $username   = undef;
    my $password   = undef;
    my $configfile = glob($opts{configfile} || $ENV{HOME} . "/.usaarc");
    
    if (-f $configfile) {
        logmsg "reading $configfile";
        open F, $configfile or do { warn "could not open $configfile: $!"; };
        while (<F>) {
            chomp;
            if (/^username:\s*(.*)/) {
                $username = $1;
            }
            elsif (/^password:\s*(.*)/) {
                $password = $1;
            }
        }
        close F;
    }

    $username = $opts{username} if defined $opts{username};
    $password = $opts{password} if defined $opts{password};

    unless (defined $username && defined $password) {
        print STDERR "cannot login to USAA without username and password\n";
        # this would be a good point to get the username and password, and 
        # to store it in ~/.usaarc.
        exit 1;
    }

    my @postdata = (
                    "PS_RESPONSETIMESTAMP"                              => "1075395286897",
                    "PS_TASKNAME"                                       => "",
                    "PS_PAGEID"                                         => "logon",
                    "PS_DYNAMIC_ACTION"                                 => "",
                    "PS_ACTION_CONTEXT"                                 => "",
                    "usaa_number"                                       => $username,
                    "password"                                          => $password,
                    "Submitted"                                         => "Yes",
                    "PsButton_\x5Baction\x5Dsubmit\x5B\x2Faction\x5D.x" => "18",
                    "PsButton_\x5Baction\x5Dsubmit\x5B\x2Faction\x5D.y" => "13",
                   );

    # log in
    dopost($url, \@postdata);

    # get account info
    my $accthtml = dopost("https://www.gc.usaa.com/inet/ent_accounts/CpAccounts");

    # This nobr stuff fouls up the XML parser. We don't need it anyway.
    $accthtml =~ s-</?nobr>--g;

    # USAA is also using plain old ampersands in text fields, which are invalid.
    $accthtml =~ s/(\s)&(\s)/$1&amp;$2/g;
    
    logmsg "parsing HTML ...\n";
    my $data = XML::LibXML->new->parse_html_string($accthtml);
    logmsg "data parsed: $data";
    
    $data;
}


sub get_balances {
    my ($class, %opts) = @_;

    $verbose = $opts{verbose} if defined $opts{verbose};
    
    my $doc = $class->fetch_data(%opts);
    # my $doc = $opts{file} ? XML::LibXML->new->parse_html_file('/tmp/usaa3.out') : $class->fetch_data(%opts);
    
    logmsg Dumper($doc);

    my @accounts = ();
    
    # look for dollar signs in text:
    my @results = $doc->findnodes('//td/text()[contains(., "$")]');
    
    for my $result (@results) {
        logmsg "looking up $result\n";
        logmsg "\$result->getValue(): " . $result->getValue();
        $result->getValue() =~ /^\s*\$(.*?)\s*$/ms;
        my $balance = $1;
        $balance =~ s/\,//g;    # a hopeful "g"
        logmsg "balance: $balance";

        # up and over to the account name:
        my $acct = $result->findvalue('ancestor::tr[1]/td[1]/input/@value');

        unless ($acct) {
            # insurance information is stored differently, compared to the
            # location of the data:
            logmsg "looking up insurance info ...";
            $acct  = $result->findvalue('ancestor::table/preceding-sibling::table[1]/tr[1]/td[1]/span[1]/text()');
        }

        logmsg "storing $acct => $balance";
        #$accounts{$acct} = $balance;

        push @accounts, (bless {
            balance    => $balance,
            name       => $acct,
            sort_code  => undef,
            account_no => undef
        }, "Finance::Bank::USAA::Account");
    }

    for (@accounts) {
        logmsg "account: $_";
    }

    @accounts;
}


sub check_balance {
    my ($class, %opts) = @_;
    $class->get_balances(%opts);
}
                 

sub display_balances {
    my ($class, %opts) = @_;

    my @accounts = $class->get_balances(%opts);
    my $format   = $opts{format} || "%20s -> %10s\n";

    for my $acct (@accounts) {
        printf $format, $acct->name, $acct->balance;
    }
}


# straight from Finance::Bank::LloydsTSB

package Finance::Bank::USAA::Account;

# Basic OO smoke-and-mirrors Thingy
no strict;

sub AUTOLOAD { my $self=shift; $AUTOLOAD =~ s/.*:://; $self->{$AUTOLOAD} }

sub new {
    my ($class, %opts) = @_;
    bless { %opts }, $class;
}


1;

__END__

=head1 NAME

Finance::Bank::USAA - Check your USAA accounts from Perl

=head1 SYNOPSIS

  use Finance::Bank::USAA;
  for my $account (Finance::Bank::USAA->get_balances(
      username  => $u,
      password  => $p
  )) {
      printf "%20s -> %s\n", $account->name, $account->balance;
  }

  # one liner:
  perl -MFinance::Bank::USAA -e 
    'Finance::Bank::USAA->display_balances(username => $u, password => $p)

=head1 DESCRIPTION

This module provides an interface to the USAA online banking system at
C<http://www.usaa.com/>. Since this module uses LWP::Simple, you will need
either C<Crypt::SSLeay> or C<IO::Socket::SSL> installed for HTTPS.

=head2 Class Methods

Each class method, except for C<dopost>, requires the username and password. 
This may be provided one of three ways:

    $HOME/.usaarc

    configfile => /path/to/your/config/file

    username => "1234567", password => "s3cr3t"

See C<FILES> for more information.

The following are in descending order of their "public-ness", i.e., how likely
the user is to need to call them directly.

=head3 Parameters

=over 4

=item username => STRING

Defines the username.

=item password => STRING

Defines the password.

=item verbose => NUM

Enables debugging output.

=back

=head3 Methods

=over 4

=item get_balances(... parameters ... )

=item check_balance(... parameters ... )

These two methods are identical; C<check_balances> is provided for consistency
with other similar Finance::Bank::* modules, such as Finance::Bank::LloydsTSB.

Each method returns an array of accounts in the format:

=over 4

=item balance

The current balance, as a floating-point number.

=item name

The account name.

=item sort_code

Undefined. This is included for consistency with other Finance::Bank::* modules.

=item account_no

Undefined. This is included for consistency with other Finance::Bank::* modules.

=back

=item display_balances(... parameters ...)

Displays the accounts in the given format, or "%20s -> %10s\n" if none provided.

=item fetch_data(... parameters ...)

Gets the account data from USAA, returning an XML document.

=item dopost($url, $postdata)

Sends the POST request to the given URL. C<postdata>, which is optional, is a
reference to an array that is passed to the POST request. Returns the resulting
content. No other parameters are used.

=back

=head2 Class Variables

=over 4

=item verbose

Setting this to a non-zero value results in debugging output.

=back

=head1 FILES

=over 4

=item $HOME/.usaarc

=item configfile => /path/to/your/config/file

A file containing the username and password in the format:

    username: 1234567
    password: s3cr3t

Note that this file should be readable by the user invoking this module; it
B<should not> be readable by anyone else. A forthcoming version of this module
may support encryption of said file.

=back

=head1 CAVEATS

(Verbatim from Finance::Bank::LloydsTSB) This is code for B<online banking>,
and that means B<your money>, and that means B<BE CAREFUL>. You are encouraged,
nay, expected, to audit the source of this module yourself to reassure yourself
that I am not doing anything untoward with your banking data. This software is
useful to me, but is provided under B<NO GUARANTEE>, explicit or implied.

For security reasons, the command-line version is not recommended.

This module uses the web interface at http://www.usaa.com, which is subject to
change, so it is likely to go out of date. Please check CPAN
(http://cpan.perl.org) for updates.

=head1 AUTHOR

Jeff Pace C<jpace@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2004 by Jeff Pace.

This library is free software; you may redistribute it and/or modify it under
the same terms as Perl itself.

=cut
