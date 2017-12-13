/*
    Author: Thomas Rolinger (tbrolin@cs.umd.edu)
    Date:   12/07/2017
    File:   main.chpl

    Description:    This is the main/driver program.
*/

use Base;
use splatt_IO;
use sptensor;
use Args;
use Stats;
use CSF;

proc main(args: [] string)
{
    // Parse command line arguments
    var cpdArgs : cpd_cmd_args = new cpd_cmd_args();
    cpdArgs.parseArgs(args);
    
    // Print a header
    writeln("****************************************************************");
    writeln("SPLATT + Chapel v1.0");
    writeln("****************************************************************");
    writeln("");

    // Create sptensor and parse the input file
    var tt : sptensor_t;
    tt = new sptensor_t();
    tt.tt_read(cpdArgs.tensorFile);

    // Print basic tensor stats
    stats_tt(tt, cpdArgs.tensorFile);

    // csf is an array. Depending on the csf allocation
    // type we have, each element in the array will be a csf
    // for that correspond mode:
    // one : csf[0] is only CSF we care about
    // two : csf[0] and csf[1]
    // all : all elements in csf
    var csf = csf_alloc(tt, cpdArgs);

    var nmodes : int = tt.nmodes;

    // Now that the CSF is built, we no longer need the sptensor tt
    delete tt;
    
    // Print CPD stats
    cpd_stats(csf, cpdArgs);
}
