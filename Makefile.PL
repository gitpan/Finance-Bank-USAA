use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'		=> 'Finance::Bank::USAA',
    'VERSION_FROM'	=> 'USAA.pm', # finds $VERSION
    'PREREQ_PM'		=> {  # e.g., Module::Name => 1.1
        "WWW::Mechanize" => "0",
        "HTML::TokeParser::Simple" => "0",
        "WWW::Mechanize" => "0",
        "HTML::TableExtract" => "0",
        "DateTime::Format::Strptime" => "0",
        "Data::Dumper" => "0",
    },
    ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM => 'USAA.pm', # retrieve abstract from module
       AUTHOR     => 'Jeff Pace <jpace@cpan.org>') : ()),
);
