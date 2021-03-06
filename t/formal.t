use strict;
use warnings;
use File::Basename;
use File::Compare;
use File::Spec;
use File::Slurp;
use Cwd qw(abs_path getcwd chdir);

use CATS::Formal::Generators::XML;
use CATS::Formal::Generators::TestlibValidator;

my $clear; BEGIN {$clear = 1;}
my @tests;
my $compiler;
my $tests_dir;
my $root_dir;

sub check_compiler {
    ($compiler) = @_;
    my $hello_world =<<CPP
#include <iostream>
using namespace std;
int main() {
    cout << "Hello World" << endl;
}
CPP
    ;
    open(my $fh, '>', 'hello_world.cpp');
    print $fh $hello_world;
    close $fh;
    my $compile = "$compiler -o hello_world.exe hello_world.cpp";
    system $compile;
    unlink "hello_world.cpp";
    if ($? >> 8) {
        print "$compiler bad compiler\n";
        die;
    }
    my $out = `hello_world.exe`;
    if ($clear) {
        unlink 'hello_world.exe';
    }
    $out ne "Hello World\n" and print "wrong output: $out" and die;
    print "used compiler $compiler\n"
}

BEGIN {
    if ($#ARGV > -1) {
        check_compiler(@ARGV);
    }
    $tests_dir = dirname(abs_path(__FILE__));
    $root_dir = dirname(dirname(dirname($tests_dir)));
    print "$tests_dir\n$root_dir\n";
    push @tests, map {run => \&run_parser_test, file => $_} => <$tests_dir/parser/*.fd>;
    push @tests, map {
        run => \&run_validator_test,
        file => $_,
        prepare => \&prepare_testlib_validator,
        validate => \&testlib_validate,
        name => 'testlib'
    } => <$tests_dir/validator/*.fd> if $compiler;
    push @tests, map {
        run => \&run_validator_test,
        file => $_,
        prepare => \&prepare_universal_validator,
        validate => \&universal_validate,
        name => 'universal'
    } => <$tests_dir/validator/*.fd>;
}

use lib $root_dir;
use Test::More tests => 3 + scalar @tests;
my @suffix_to_save = qw(.fd .in .ans);

sub compare_files_ok {
    my ($file1, $file2, $comment) = @_;
    ok(compare($file1, $file2) == 0, $comment);
}

sub in {
    my ($e, @a) = @_;
    for (@a){
        return 1 if $e eq $_;
    }
    return 0;
}

sub clear {
    my ($dir) = @_;
    if ($clear) {
        print "cleaning directory $dir...\n";
        my @exclude = ("$dir/testlib.h", map <$dir/*$_> => @suffix_to_save);
        my @all = grep !in($_, @exclude) => <$dir/*>;
        unlink @all;
    }
}

sub generate_and_write {
    my ($generator, $file, $out) = @_;
    my $src = read_file($file);
    my $result = CATS::Formal::Formal::generate(
        $generator,
        INPUT => $src
    ) || CATS::Formal::Error::get();
    write_file("$out", $result);
}

sub prepare_testlib_validator {
    my ($file) = @_;
    my ($name, $dir, $suffix) = fileparse($file, '.fd');
    generate_and_write(
        CATS::Formal::Generators::TestlibValidator->new(),
        $file,
        "$dir$name.cpp"
    );
    $compiler or return fail('undefined compiler');
    my $compile =
        "$compiler -o $dir$name.exe $dir$name.cpp";
    print "compiling... $file -> testlib\n";
    system($compile);
    if ($? >> 8) {
        fail("$file - not compiled -> testlib");
        return ;
    }
    return "$dir$name.exe";
}

sub testlib_validate {
    my ($test_file, $executable) = @_;
    $executable = File::Spec->canonpath($executable);
    $test_file = File::Spec->canonpath($test_file);
    return `$executable < $test_file 2>&1`;
}

sub prepare_universal_validator {
    my $src = read_file($_[0]);
    return {
        INPUT => $src
    };
}

sub universal_validate {
    my ($test_file, $from) = @_;
    my $src = read_file($test_file);
    return CATS::Formal::Formal::validate($from, {INPUT => $src});
}

sub run_parser_test {
    my ($test_obj) = @_;
    my $file = $test_obj->{file};
    my ($name, $dir, $suffix) = fileparse($file, '.fd');
    generate_and_write(
        CATS::Formal::Generators::XML->new(),
        $file,
        "$dir$name.out"
    );
    compare_files_ok("$dir$name.ans", "$dir$name.out", $file);
}

sub run_validator_test {
    my ($test_obj) = @_;
    my $file = $test_obj->{file};
    my $prepare = $test_obj->{prepare};
    my $validate = $test_obj->{validate};
    my $validator_name = $test_obj->{name};
    my ($name, $dir, $suffix) = fileparse($file, '.fd');
    my $prepared = $prepare->($file) || return;
    my @sub_tests = <$dir$name.*.in>;
    subtest $file => sub {
        plan tests => scalar @sub_tests;
        for my $st (@sub_tests) {
            my $in_name = $dir . basename($st, '.in');
            $in_name =~ /.*(fail|ok)\.\d+$/;
            my $should_be_ok = $1 eq 'ok';
            my $output = $validate->($st, $prepared) || '';
            my $res = $output && !$should_be_ok || !$output && $should_be_ok;
            write_file("$in_name.$validator_name.out", $output);
            ok($res, "$st - $validator_name");
        }
    }
}

sub run_validator_tests{
    my ($validator_id, $prepare, $validate, @validator_tests) = @_;
    for my $file (@validator_tests) {
        my ($name, $dir, $suffix) = fileparse($file, '.fd');
        my $prepared = $prepare->($file) || return;
        my @sub_tests = <$dir$name.*.in>;
        subtest $file => sub {
            for my $st (@sub_tests) {
                my $in_name = $dir . basename($st, '.in');
                $in_name =~ /.*(fail|ok)\.\d+$/;
                my $should_be_ok = $1 eq 'ok';
                my $output = $validate->($st, $prepared) || '';
                my $res = $output && !$should_be_ok || !$output && $should_be_ok;
                write_file("$in_name.$validator_id.out", $output);
                ok($res, "$st - $validator_id");
            }
        }
    }
}

BEGIN {use_ok('CATS::Formal::Formal')};

$_->{run}->($_) for @tests;

{
    my $error = CATS::Formal::Formal::validate({
        INPUT => "integer name=A;",
        OUTPUT => "integer name=A, range=[0, 10000];",
    }, {
        OUTPUT => "1000"
    },
        1
    );
    is($error, undef, "Enable: skip validation if data is missed");
}

{
    my $error = CATS::Formal::Formal::validate({
            INPUT => "integer name=A",
            OUTPUT => "integer name=A, range=[0, INPUT.A];",
        }, {
            OUTPUT => "1000"
        },
        0
    );
    isnt($error, undef, "Disable: skip validation if data is missed");
}

clear("$tests_dir/parser");
clear("$tests_dir/validator");

1;
