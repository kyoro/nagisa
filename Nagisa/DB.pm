package Nagisa::DB;
use strict;
use warnings;
use base 'Class::Accessor::Fast';
use DBI;
use YAML::XS;

__PACKAGE__->mk_accessors(qw/
        dbh
/);

sub connect {
    my $settings;
    eval{
        $settings = YAML::XS::LoadFile(
                $ENV{NAGISA_LIB_ROOT}."/config/db_config.yaml");
    };
    if($@){
        $settings = {
            db_username => 'root',
            db_password => '',
        }
    }
    my $class = shift;
    my %args = (
            dsn      => undef,
            username => $settings->{db_username},
            password => $settings->{db_password},
            @_ );
    if(!$args{dsn} || !$args{username} || !$args{password}){
        return;
    }
    my $dbh = DBI->connect($args{dsn}, $args{username}, $args{password});
    return unless $dbh;
    $dbh->do("set names utf8");
    my $self = $class->new({
            dbh => $dbh,
            });
    return $self;
}

sub new {
    my ($class, $args) = @_;
    my $self;
    if(ref $args eq 'HASH') {
        $self = $class->SUPER::new($args);
    }else{
        $self = $class->SUPER::new;
    }
    return $self;
}

1;
