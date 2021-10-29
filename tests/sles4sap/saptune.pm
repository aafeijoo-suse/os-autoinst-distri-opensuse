# SUSE's openQA tests
#
# Copyright 2017-2018 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: saptune availability test
# Maintainer: Alvaro Carvajal <acarvajal@suse.de>

use base "sles4sap";
use testapi;
use utils "zypper_call";
use version_utils "is_sle";
use Utils::Architectures;
use strict;
use warnings;

sub run {
    my ($self) = @_;

    $self->select_serial_terminal;

    # saptune is not installed by default on SLES4SAP 12 on ppc64le
    zypper_call "-n in saptune" if (is_ppc64le() and is_sle('<15'));

    assert_script_run "saptune daemon status";
}

1;
