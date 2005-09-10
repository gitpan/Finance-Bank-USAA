#!/usr/bin/perl

package Finance::Bank::USAA;

use strict;
use base qw/Class::Accessor::Fast/;
use WWW::Mechanize;
use HTML::TokeParser::Simple;
use HTML::TableExtract;
use DateTime::Format::Strptime;
use warnings;

use Data::Dumper;

our $VERSION = '1.5';

__PACKAGE__->mk_accessors('_mech');

our $usaa_login = 'https://www.lc.usaa.com/inet/ent_logon/Logon';

our $verbose = 0;

sub logmsg {
    if ($verbose) {
        my @msg = @_;
        chomp @msg;
        my ($pkg,  $fname, $line, undef) = caller(0);
        my (undef, undef,  undef, $sub)  = caller(1);
        printf STDERR "[%-50s:%-5d] {%-50s} ", $fname, $line, $sub;
        print STDERR @msg, "\n";
    }
}

sub stackmsg {
    if ($verbose) {
        my @msg = @_;
        chomp @msg;
        for my $lvl (0 .. 10) {
            my ($pkg,  $fname, $line, undef) = caller($lvl);
            my (undef, undef,  undef, $sub)  = caller($lvl + 1);
            last unless $fname;
            $sub ||= "";
            printf STDERR "[%-50s:%-5d] {%-50s} ", $fname, $line, $sub;
            print STDERR @msg, "\n";
            @msg = ("\"");
        }
    }
}

sub new {
    my ($class, %args) = @_;
    
    my $self = { %args };
    bless $self, $class;
    
    $self->_mech(WWW::Mechanize->new(autocheck => 1,
                                     onwarn => \&Carp::cluck,
                                     onerror => \&Carp::confess));
    
    return $self;
}

# login to a USAA account
sub login {
    my $self = shift;
    
    $self->_mech->get($usaa_login);
    $self->_mech->submit_form(form_name => 'Logon',
                              fields => {
                                         j_username => $self->{username},
                                         j_password => $self->{password},
                                        },
                             );
    
    $self->{logged_in} = 1 if $self->_mech->success;
}

# support the same interface as other Bank::Finance::* modules:
sub check_balance {
    my $class = shift;
    my $self = $class->new(@_);
    $self->accounts(transactions => 0);
}

# get all available accounts
sub accounts {
    my $self = shift;
    my %opts = @_;

    stackmsg "getting accounts";
    
    $self->login unless $self->{logged_in};
    
    my $accounts_html = $self->_mech->follow_link(text => "My Accounts")->content;
    
    my $p = HTML::TokeParser::Simple->new(string => $accounts_html);
    
    $self->{accounts} = [];
    my $current_account = {};
    
    # XXX: Rewrite using TableExtract

    my $is_insurance = 0;
    
    while (my $token = $p->get_token) {   
        
        # look for account names.
        # USAA uses some browser detection and shows submit buttons to some
        # browsers and Javascript links to others.  Mechanize seems to get the 
        # nice submit buttons.
        if ($token->is_start_tag('input')) {
            if ($token->get_attr('name') =~ /ToBkAccounts/) {
                $current_account->{name} = $token->get_attr('value');
                $is_insurance = 0;
            }
        }
        elsif ($token->is_start_tag('a')) {
            if (defined($token->get_attr('href')) && $token->get_attr('href') =~ /PcAutoBillView/) {
                $token = $p->get_token; # <nobr>
                $token = $p->get_token; # text
                $current_account->{name} = $token->as_is;
                $is_insurance = 1;
            }
        }

        # look for nobr tags, these surround the other data we need
        my $isstart = $token->is_start_tag('nobr');

        # Perl squawks about "Use of uninitialized value in string eq" here, and
        # I don't know why, and nothing bad happens.

        no warnings qw(uninitialized);
        
        if (defined $isstart && $isstart) {
            $token = $p->get_token;
            my $data = $token->as_is;

            # USAA wraps negative numbers in parentheses and red text:
            if ($token->is_start_tag('font') && $token->get_attr('color') eq '#ff0000') {
                $token = $p->get_token;
                $data = $token->as_is;
            }
            
            if ($data =~ /^\d/) {
                $current_account->{number} = $data;
            }
            elsif ($data =~ /^\(?\$/) {
                $current_account->{balance} = $self->_parse_money($data);
            }
        }
        elsif ($is_insurance && $token->is_start_tag('td') && $token->get_attr('class') eq "dataQuantity") {
            $token = $p->get_token;
            my $data = $token->as_is;

            # insurance isn't numbered
            $current_account->{number} = "n/a";
            if ($data =~ /^\$/) {
                $current_account->{balance} = $self->_parse_money($data);
            }
        }

        # back to all warnings again.
        use warnings;

        if ($current_account->{name} && defined $current_account->{balance}) {
            
            # skip this if we're only looking for a certain account number
            next if $opts{number} && $current_account->{number} ne $opts{number};
                 
            my $transactions = {};
            if ($opts{transactions}) {
                $transactions = $self->transactions(account_name => $current_account->{name});
            }
                 
            my $account = bless {
                                 name        => $current_account->{name},
                                 number      => $current_account->{number},
                                 account_no  => $current_account->{number},
                                 balance     => $current_account->{balance},
                                 deposits    => $transactions->{deposits},
                                 checks      => $transactions->{checks},
                                 debits      => $transactions->{debits},
                                 activity    => $transactions->{activity},
                                }, "Finance::Bank::USAA::Account";
            $current_account = {};

            return $account if $opts{number};

            push @{ $self->{accounts} }, $account;
        }
    }
        
    return wantarray ? @{ $self->{accounts} } : $self->{accounts};
}

# get a list of recent transactions
sub transactions {
    my $self = shift;
    my %opts = @_;
    
    unless ($self->_mech->uri =~ /CpAccounts$/) {
        # this is at the top on all accounts, including insurance.
        $self->_mech->follow_link(text => "My Accounts");
    }

    my $transactions = {};
    
    $self->_mech->form_name('cp_accounts');

    # I really want mech->has_button("submit", value => $opts{account_name})
    my $form = $self->_mech->{form}; # HTML::Form

    my $transaction_html = undef;

    my $i = 1;                  # one-indexed
    while (my $input = $form->find_input(undef, 'submit', $i)) {
        if ($opts{account_name} eq $input->value) {
            $transaction_html = $self->_mech->click_button(value => $opts{account_name})->content;
            last;
        }
        else {
            ++$i;
        }
    }

    unless (defined $transaction_html) {
        # couldn't find the account as a submit button, so it must be insurance
        $transaction_html = $self->_mech->follow_link(url_regex => qr/PcAutoBillView/)->content;
    }

    my %t_types = (
                   # banking:
                   deposits => "Recent Deposits",
                   checks => "Recent Paid Checks",
                   debits => "Recent ATM/Other Debits",
                   # insurance:
                   activity => "Recent Account Activity",
                 );
    
    foreach my $type (keys %t_types) {
        $transactions->{$type} = [];
        
        # TableExtract can't find out which table is which, so parse out the correct table first
        my $type_name = $t_types{$type};

        $transaction_html =~ /<h3>$type_name<\/h3>(.+?)<\/table>/ms;
        my $content = $1;
        next unless $content;
        
        my $html = $content . "</table>";
        
        my $te = HTML::TableExtract->new(decode => 0);
        $te->parse($html);
        foreach my $ts ($te->tables) {
            foreach my $row ($ts->rows) {
                # headers for Transactions and Insurance Info
                next if $row->[0] eq "Transaction Date" || $row->[1] eq "Description";
                
                # strip whitespace and newlines
                for (0 .. 1) {
                    $row->[$_] =~ s/&nbsp;//g;
                    $row->[$_] =~ s/^\s+//;
                    $row->[$_] =~ s/\s+$//;
                }
                
                # split the description into 2 fields
                my ($desc1, $desc2) = split(/\r?\n\s*/, $row->[1]);

                # pending debits (sometimes?) have the date mushed into the same
                # cell as the description.

                my $date = $self->_parse_date($row->[0]);
                unless ($date) {
                    # date parse failed in row 0 ... try what is in the description section:
                    $date = $self->_parse_date($desc1);
                    if ($date) {
                        $desc1 = $desc2;
                        $desc2 = "";
                    }
                }

                my $trans = bless {
                                   date => $date,
                                   description => $desc1,
                                   description2 => $desc2,
                                   amount => $self->_parse_money($row->[2]),
                                  }, "Finance::Bank::USAA::Transaction";
                push @{ $transactions->{$type} }, $trans;
            }
        }
    }

    return $transactions;
}

# parse date strings into DateTime objects
sub _parse_date {
    my ($self, $date) = @_;
    
    my $dtf = DateTime::Format::Strptime->new(pattern => '%b %e, %Y');
    my $parsed = $dtf->parse_datetime($date);
    unless (defined $parsed) {
        # try it again, with how USAA also formats dates (05/26/2003):
        $dtf = DateTime::Format::Strptime->new(pattern => '%m/%d/%Y');
        $parsed = $dtf->parse_datetime($date);
    }
    return $parsed;
}

# parse money string into a number
sub _parse_money {
    my ($self, $money) = @_;
    
    $money =~ /^\s*
               (\()?            # parenthesized means negative
               \$(.*?)          # the amount
               \)?              # paren
               \s*$/mxs;
    my $negative = $1 || 0;
    my $amount = $2;
    $amount =~ s/\,//g;
    return ($negative ? -1 : 1) * $amount;
}

package Finance::Bank::USAA::Account;

no strict;

sub AUTOLOAD { 
    my $self = shift; 
    $AUTOLOAD =~ s/.*:://;
    
    if (ref $self->{$AUTOLOAD} eq "ARRAY") {
        return wantarray ? @{ $self->{$AUTOLOAD} } : $self->{$AUTOLOAD};
    }
    else {
        return $self->{$AUTOLOAD};
    }
}

sub new {
    my ($class, %opts) = @_;
    bless { %opts }, $class;
}

package Finance::Bank::USAA::Transaction;

use base 'Finance::Bank::USAA::Account';

1;

__END__

=head1 NAME

Finance::Bank::USAA - Check your USAA accounts from Perl

=head1 SYNOPSIS

  use Finance::Bank::USAA;
  for my $account (Finance::Bank::USAA->check_balances(username => "myname",
                                                       password => "s3cr3t")) {
      printf "%20s -> %s\n", $account->name, $account->balance;
  }

=head1 DESCRIPTION

This module provides an interface to extracting account information from the
USAA online banking system (C<http://www.usaa.com/>).

=head3 Methods

=over 4

=item B<check_balance>(username => STRING, password => STRING)

This is a class method, returning an array of accounts in the format:

=over 4

=item B<balance>

The current balance, as a floating-point number.

=item B<name>

The account name.

=item B<number>

=item B<account_no>

These two fields are identical, representing the account number. The
"account_no" field included for consistency with other Finance::Bank::* modules.

If not applicable, this will be "n/a".

=item B<sort_code>

Undefined. This is included for consistency with other Finance::Bank::* modules.

=back

=item B<new>(username => STRING, password => STRING)

Creates and returns an instance.

=item B<accounts>(transactions => NUMBER, number => STRING)

An instance method returning an array (or reference to one) to account
information. If the number parameter is defined, the returned information will
be only for that account. If the transactions parameter is not zero,
transactions will also be returned. for the given account.

=item B<transactions>(account_name => STRING)

An instance method returning an array (or reference to one) of the transactions
for the account with the given name.

Valid account names are: 

    deposits
    checks
    debits
    activity (for insurance accounts only)

The transaction fields are: 

    date (as a DateTime object)
    description (string)
    description2 (string)
    amount (number)

=back

=head1 CAVEATS

(Verbatim from Finance::Bank::LloydsTSB) This is code for B<online banking>,
and that means B<your money>, and that means B<BE CAREFUL>. You are encouraged,
nay, expected, to audit the source of this module yourself to reassure yourself
that I am not doing anything untoward with your banking data. This software is
useful to me, but is provided under B<NO GUARANTEE>, explicit or implied.

This module uses the web interface at http://www.usaa.com, which is subject to
change, so it is likely to go out of date. Please check CPAN
(http://cpan.perl.org) for updates.

=head1 AUTHOR

Jeff Pace C<jpace@cpan.org> and Andy Grundman C<andy@hybridized.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2005 by Jeff Pace.

This library is free software; you may redistribute it and/or modify it under
the same terms as Perl itself.

=cut
