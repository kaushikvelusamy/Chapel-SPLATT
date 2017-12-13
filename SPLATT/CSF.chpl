/*
    Author: Thomas Rolinger (tbrolin@cs.umd.edu)
    Date:   12/05/2017
    File:   CSF.chpl

    Description:    This is a module file for the compressed sparse fiber
                    (CSF) data structure used to represent sparse tensors.
*/

module CSF {
    use Base;
    use sptensor;
    use Args;
    use Sort;
    use splatt_sort;
    use Assert;

    /*****************************
    *
    *   CSF sub-tree class
    *
    ******************************/
    class csf_subtree {
        var subtree_d : domain(1) = 0..DEFAULT_NNZ-1;
        var subtree : [subtree_d] int;
    }

    /*****************************
    *
    *   CSF fiber IDS class
    *
    ******************************/
    class csf_fiber_ids {
        var fiber_ids_d : domain(1) = 0..DEFAULT_NNZ-1;
        var fiber_ids : [fiber_ids_d] int;
    }

    /*****************************
    *
    *   CSF sparisty patter class
    *
    ******************************/
    class csf_sparsity {
        /** The size of each fptr and fids array */
        var nfibs : [NUM_MODES_d] int;
        /** The pointer structure for each sub-tree. fptr[f]
            marks the start of the children of node 'f'. This
            structure is a generalization of the 'rowptr' array
            used in CSR matrices
            *** Chapel note: In C, this would be an array of
                int ptrs. At first, I would just make this a
                2D array then. However, each "row" is of a
                different size and we can't do that in Chapel.
                So we need to make fptr a 1D array of objects
                that represent whatever the row is. We'll call
                these objects csf_subtrees (see above).
         */
        var fptr : [NUM_MODES_d] csf_subtree;
        /** The index of each node. These map nodes back to the
            original tensor nonzeros 
            *** Chapel note: Just like above, we need to use
                objects to correctly store this
        */
        var fids : [NUM_MODES_d] csf_fiber_ids;
        /** The actual nonzero values. This array is of length
            nfibs[nmodes-1]. Since we do not know this size at
            compile time, we will resize the domain of this
            array later */
        var vals : [CSF_SPARSITY_VALS_d] real;
    }

    /*****************************
    *
    *   CSF class
    *
    ******************************/
    class splatt_csf {
        /** Number of nonzeros */
        var nnz : int;
        /** Number of modes */
        var nmodes : int;
        /** Dimension of each mode */
        var dims : [NUM_MODES_d] int;
        /** This maps levels in the tensor to actual tensor modes.
            dim_perm[0] is the mode stored at the root level and so on.
            NOTE: do not use directly; use 'csf_depth_to_mode' instead */
        var dim_perm : [NUM_MODES_d] int;
        /** Inverse of dim_perm. This maps tensor modes to levels in the
            CSF. NOTE: do not use directly; use 'csf_mode_to_depth' instead */
        var dim_iperm : [NUM_MODES_d] int;
        /** Which tiling scheme this tensor is stored as */
        var which_tile : int;
        /** How many tiles there are */
        var ntiles : int;
        /** How many modes of the tensor (i.e. CSF levels) are tiled.
            Counted from the leaf (bottom) mode */
        var ntiled_modes : int;
        /** For a dense tiling, how many tiles along each mode */
        var tile_dims : [NUM_MODES_d] int;
        /** Sparsity structures: one for each tile. Since we
            do not know how many tiles there are yet, we'll
            resize this array later */
        var pt : [NUM_TILES_d] csf_sparsity;
    }

    /*****************************
    *
    *   Enums and Constants
    *
    ******************************/

    // The types of mode ordering available
    enum csf_mode_type 
    {  
        CSF_SORTED_SMALLFIRST,  /** sort the modes in non-decreasing order */
        CSF_SORTED_BIGFIRST,    /** sort the modes in non-increasing order */
        CSF_INORDER_MINUSONE,   /** one mode is placed first, rest naturally ordered*/
        CSF_SORTED_MINUSONE,    /** one mode is placed first, rest sorted by size */
        CSF_MODE_CUSTOM         /** custom mode ordering. dim_perm must be set! */
    };

    // CSF tile types
    enum splatt_tile_type
    {
        SPLATT_NOTILE,
        SPLATT_DENSETILE,
    }; 

    /*****************************
    *
    *   Public Functions
    *
    ******************************/
    /*########################################################################
    #   Descriptipn:    Public function for allocating CSF tensor
    #
    #   Parameters:     tt (sptensor_t):    The coordinate tensor to work from
    #                   args (cpd_cmd_args): Arguments
    #
    #   Return:         splatt_csf: The CSF tensor
    ########################################################################*/
    proc csf_alloc(tt : sptensor_t, args : cpd_cmd_args)
    {
        /*
            Array of splatt_csf's. If the allocation type is one, then
            we only create a CSF for the 1 mode, if its two then we do
            two modes and if its all, we do all modes. Regardless, we'll
            return this entire array back.
        */
        var ret : [NUM_MODES_d] splatt_csf;
        var last_mode : int = 0;
        var temp : int = 0;

        select(args.numCSF) {
            when "one" {
                ret[0] = new splatt_csf();
                p_mk_csf(ret[0], tt, csf_mode_type.CSF_SORTED_SMALLFIRST, 0, args);
            }
            when "two" {
                var ret : [0..1] splatt_csf;
                ret[0] = new splatt_csf();
                ret[1] = new splatt_csf();
                p_mk_csf(ret[0], tt, csf_mode_type.CSF_SORTED_SMALLFIRST, 0, args);
                /* 
                    Don't tile last mode. Turn tiling off in args, allocate and then
                    reset it back to whatevr it was
                */
                var oldTile = args.tiling;
                args.tiling = 0;
                last_mode = ret[0].dim_perm[tt.nmodes-1];
                p_mk_csf(ret[1], tt, csf_mode_type.CSF_SORTED_MINUSONE, last_mode, args);
                args.tiling = oldTile;            
            }
            when "all" {
                for m in NUM_MODES_d {
                    ret[m] = new splatt_csf();
                    p_mk_csf(ret[m], tt, csf_mode_type.CSF_SORTED_MINUSONE, m, args);
                }
            }   
            otherwise {
                writeln("ERROR: CSF allocation type '", args.numCSF, "' not recognized");
            }
        }
        return ret;
    }

    /*########################################################################
    #   Descriptipn:    Order the indices of the tensor according to mode type.
    #
    #   Parameters:     dims ([]int):           Array of mode sizes
    #                   nmodes (int):           Number of modes
    #                   which (csf_mode_type):  Allocation scheme for CSF tensor
    #                   mode (int):             Which mode 
    #                   perm_dims ([]int):      Maps level of tensor to tensor modes
    #
    #   Return:         None
    ########################################################################*/
    proc csf_find_mode_order(dims : [NUM_MODES_d] int, nmodes : int, which : csf_mode_type,
                             mode : int, perm_dims : [NUM_MODES_d] int)
    {
        select(which) {
            when csf_mode_type.CSF_SORTED_SMALLFIRST {
                p_order_dims_small(dims, nmodes, perm_dims);
            }
            when csf_mode_type.CSF_SORTED_BIGFIRST {
                p_order_dims_large(dims, nmodes, perm_dims);
            }
            when csf_mode_type.CSF_INORDER_MINUSONE {
                p_order_dims_inorder(dims, nmodes, mode, perm_dims);
            }
            when csf_mode_type.CSF_SORTED_MINUSONE {
                p_order_dims_minusone(dims, nmodes, mode, perm_dims);
            }
            otherwise {
                writeln("ERROR: csf_mode_type ", which, " not recognized");
            }
        }
    }

    /*****************************
    *
    *   Private Functions
    *
    ******************************/
    
    /*########################################################################
    #   Descriptipn:    Allocate and fill CSF tensor.
    #
    #   Parameters:     ct (splatt_csf):            The CSF tensor to fill.
    #                   tt (sptensor_t):            The coordinate tensor to work from
    #                   mode_type (csf_mode_type):  The allocation scheme for 
    #                                               the CSF tensor.
    #                   mode (int):                 Which mode we are converting for
    #                   splatt_opts (cpd_cmd_args): Arguments
    #
    #   Return:         None
    ########################################################################*/
    private proc p_mk_csf(ct : splatt_csf, tt : sptensor_t, mode_type : csf_mode_type,
                          mode : int, splatt_opts : cpd_cmd_args)
    {
        // Set nnz, nmodes and dims in CSF
        ct.nnz = tt.nnz;
        ct.nmodes = tt.nmodes;
        ct.dims = tt.dims;

        // Get the indices in order
        csf_find_mode_order(tt.dims, tt.nmodes, mode_type, mode, ct.dim_perm);  

        // Tiling option
        ct.which_tile = splatt_opts.tiling;
        select(ct.which_tile) {
            when 0 {
                p_csf_alloc_untiled(ct, tt);
            }
            when 1 {
                p_csf_alloc_densetile(ct, tt, splatt_opts);
            }
            otherwise {
                writeln("ERROR: Tiling option not supported");
            }
        }
    }

    /*########################################################################
    #   Descriptipn:    Find a permutation of modes that results in
    #                   non-increasing mode size.
    #
    #   Parameters:     dims ([]int):       Array of mode sizes
    #                   nmodes (int):       Number of modes
    #                   perm_dims ([]int):  Maps level of tensor to tensor modes
    #
    #   Return:         None
    ########################################################################*/
    private proc p_order_dims_small(dims : [NUM_MODES_d] int, nmodes : int,  perm_dims : [NUM_MODES_d] int)
    {
        var sorted : [NUM_MODES_d] int;
        var matched : [NUM_MODES_d] int;
        sorted = dims;
        matched = 0;
        // Sort 'sorted' using quicksort
        sort(sorted);

        /*
            Re-associate the mode numbers with the sorted
            dimensions    
        */
        for mfind in NUM_MODES_d {
            for mcheck in NUM_MODES_d {
                if sorted[mfind] == dims[mcheck] && !matched[mcheck] {
                    perm_dims[mfind] = mcheck;
                    matched[mcheck] = 1;
                    break;
                }
            }
        }
    }

    /*########################################################################
    #   Descriptipn:    Find a permutation of modes that results in
    #                   non-decreasing mode size.
    #
    #   Parameters:     dims ([]int):       Array of mode sizes
    #                   nmodes (int):       Number of modes
    #                   perm_dims ([]int):  Maps level of tensor to tensor modes
    #
    #   Return:         None
    ########################################################################*/
    private proc p_order_dims_large(dims : [NUM_MODES_d] int, nmodes : int,  perm_dims : [NUM_MODES_d] int)
    {
        var sorted : [NUM_MODES_d] int;
        var matched : [NUM_MODES_d] int;
        sorted = dims;
        matched = 0;
        // Sort 'sorted' using quicksort, decreasing order
        sort(sorted, comparator=reverseComparator);

        /*
            Re-associate the mode numbers with the sorted
            dimensions    
        */
        for mfind in NUM_MODES_d {
            for mcheck in NUM_MODES_d {
                if sorted[mfind] == dims[mcheck] && !matched[mcheck] {
                    perm_dims[mfind] = mcheck;
                    matched[mcheck] = 1;
                    break;
                }
            }
        }
    }

    /*########################################################################
    #   Descriptipn:    Find a permutation of modes such that the first mode
    #                   is 'custom-mode' and the remaining are sorted in
    #                   non-increasing order.
    #
    #   Parameters:     dims ([]int):       Array of mode sizes
    #                   nmodes (int):       Number of modes
    #                   custom_mode (int):  The mode to place first
    #                   perm_dims ([]int):  Maps level of tensor to tensor modes
    #
    #   Return:         None
    ########################################################################*/
    private proc p_order_dims_minusone(dims : [NUM_MODES_d] int, nmodes : int,  
                                       custom_mode : int, perm_dims : [NUM_MODES_d] int)
    {
        p_order_dims_small(dims, nmodes, perm_dims);

        /* 
            Find where custom_mode was placed and adjust from there. 
            Get a c-pointer to perm_dims so we can use memmove.
        */
        for m in NUM_MODES_d {
            if perm_dims[m] == custom_mode {
                var arrayPtr = c_ptrTo(perm_dims);
                c_memmove(arrayPtr+1, arrayPtr, m*8);
                perm_dims[0] = custom_mode;
                break;
            }
        }
    }

    /*########################################################################
    #   Descriptipn:    Find a permutation of modes such that the first mode
    #                   is 'custom-mode' and the remaining are naturally ordered
    #                   (0,1, ...).
    #
    #   Parameters:     dims ([]int):       Array of mode sizes
    #                   nmodes (int):       Number of modes
    #                   custom_mode (int):  The mode to place first
    #                   perm_dims ([]int):  Maps level of tensor to tensor modes
    #
    #   Return:         None
    ########################################################################*/
    private proc p_order_dims_inorder(dims : [NUM_MODES_d] int, nmodes : int,
                                       custom_mode : int, perm_dims : [NUM_MODES_d] int)
    {
        // Initialize to natural ordering
        perm_dims = 0..nmodes-1;

        /* 
            Find where custom_mode was placed and adjust from there. 
            Get a c-pointer to perm_dims so we can use memmove.
        */
        for m in NUM_MODES_d {
            if perm_dims[m] == custom_mode {
                var arrayPtr = c_ptrTo(perm_dims);
                c_memmove(arrayPtr+1, arrayPtr, m*8);
                perm_dims[0] = custom_mode;
                break;
            }
        }
    }

    /*########################################################################
    #   Descriptipn:    Allocate and fill a CSF tensor from a coordinate tensor
    #                   without tiling.
    #
    #   Parameters:     ct (splatt_csf):    The CSF tensor to fill out
    #                   tt (sptensor_t):    The sparse tensor to start from
    #
    #   Return:         None
    ########################################################################*/
    proc p_csf_alloc_untiled(ct : splatt_csf, tt : sptensor_t)
    {
        var nmodes : int = tt.nmodes;
        tt_sort(tt, ct.dim_perm[0], ct.dim_perm);

        ct.ntiles = 1;
        ct.tile_dims = 1;

        // Resize pt array/domain
        NUM_TILES_d = 0..ct.ntiles-1;

        ct.pt[0] = new csf_sparsity();
        var pt = ct.pt[0];

        // last row of fptr is just nonzero inds
        pt.nfibs[nmodes-1] = ct.nnz;
        // Resize CSF_SPARSITY_VALS_d to be size nfibs[nmodes-1]
        CSF_SPARSITY_VALS_d = 0..pt.nfibs[nmodes-1];
        // Create fiber_ids and subtrees for each mode
        for m in 0..nmodes-1 {
            pt.fids[m] = new csf_fiber_ids();
            pt.fptr[m] = new csf_subtree();
        }

        // Last mode's fiber ids size is nnz
        pt.fids[nmodes-1].fiber_ids_d = 0..ct.nnz-1;

        // Get pointers to arrays so we can do some memcpys
        var fidsPtr = c_ptrTo(pt.fids[nmodes-1].fiber_ids);
        var indPtr = c_ptrTo(tt.ind[ct.dim_perm[nmodes-1],0..ct.nnz-1]);
        var ptValsPtr = c_ptrTo(pt.vals);
        var ttValsPtr = c_ptrTo(tt.vals);
        c_memcpy(fidsPtr, indPtr, ct.nnz*8);
        c_memcpy(ptValsPtr, ttValsPtr, ct.nnz*8);

        // setup a basic tile ptr for one tile
        var nnz_ptr : [0..1] int;
        nnz_ptr[0] = 0;
        nnz_ptr[1] = tt.nnz;

        // create fptr entries for the rest of the modes, working down from roots.
        // Skip the bottom level (nnz)
        for m in 0..nmodes-2 {
            p_mk_fptr(ct, tt, 0, nnz_ptr, m);
        }
    }

    /*########################################################################
    #   Descriptipn:    Reorder the nonzeros in a sparse tensor using dense
    #                   tiling and fill a CSF tensor with the data
    #
    #   Parameters:     ct (splatt_csf):            The CSF tensor to fill out
    #                   tt (sptensor_t):            The sparse tensor to start from
    #                   splatt_opts (cpd_cmd_args): The arguments/options
    #
    #   Return:         None
    ########################################################################*/
    proc p_csf_alloc_densetile(ct : splatt_csf, tt : sptensor_t, splatt_opts : cpd_cmd_args)
    {
        return;
    }

    /*########################################################################
    #   Descriptipn:    Construct the sparsity structure of any mode but the
    #                   last. The first (root) is handled by p_mk_outerptr
    #                   and the first is simply a copy of the nonzeros
    #
    #   Parameters:     ct (splatt_csf):        The CSF tensor to construct
    #                   tt (sptensor_t):        The sparse tensor (sorted)
    #                   tile_id (int):          The ID of the tile to make
    #                   nnztile_ptr (int []):   A pointer into 'tt' that marks
    #                                           the start of each tile.
    #                   mode (int):             The mode we are making        
    #
    #   Return:         None
    ########################################################################*/
    private proc p_mk_fptr(ct : splatt_csf, tt : sptensor_t, tile_id : int, nnztile_ptr, mode : int)
    {   
        assert(mode < ct.nmodes);

        var nnzstart : int = nnztile_ptr[tile_id];
        var nnzend : int = nnztile_ptr[tile_id+1];
        var nnz : int = nnzend - nnzstart;        
        
        // outer mode is easy; just look at outer indices
        if mode == 0 {
            p_mk_outerptr(ct, tt, tile_id, nnztile_ptr);
            return;
        }

        // the mode after accounting for dim_perm
        // Get a c ptr to it to make this easier
        var indPtr = c_ptrTo(tt.ind[ct.dim_perm[mode],0..ct.nnz-1]);
        var ttind = indPtr + nnzstart;       
 
        // grab sparsity pattern
        var pt = ct.pt[tile_id];

        // we will edit this to point to the new fiber indx instead
        // of nnz   
        var fprev = pt.fptr[mode-1].subtree;

        // First count nfibers
        var nfibs : int = 0;
        // For each 'slice' in the previous dimension
        for s in 0..pt.nfibs[mode-1]-1 {
            nfibs += 1; // one by default per slice
            // count fibers in current hyperplane
            for f in fprev[s]+1..fprev[s+1]-1 {
                if ttind[f] != ttind[f-1] {
                    nfibs += 1;
                }
            }
            
        }
        pt.nfibs[mode] = nfibs;

        // Resize this mode's subtree size and fiber ids size
        pt.fptr[mode].subtree_d = 0..(nfibs+1)-1;
        pt.fids[mode].fiber_ids_d = 0..nfibs-1;

        var fpPtr = c_ptrTo(pt.fptr[mode].subtree);
        var fiPtr = c_ptrTo(pt.fids[mode].fiber_ids);
        fpPtr[0] = 0;

        // now fill in fiber info
        var nfound : int = 0;
        for s in 0..pt.nfibs[mode-1]-1 {
            var start : int = fprev[s]+1;
            var end : int = fprev[s+1];
            // mark start of subtree
            fprev[s] = nfound;
            fiPtr[nfound] = ttind[start-1];
            fpPtr[nfound] = start-1;
            nfound += 1;
            // mark fibers in current hyperplane
            for f in start..end-1 {
                if ttind[f] != ttind[f-1] {
                    fiPtr[nfound] = ttind[f];
                    fpPtr[nfound] = f;
                    nfound += 1;
                }
            }
        }
        // mark end of last hyperplane
        fprev[pt.nfibs[mode-1]] = nfibs;
        fpPtr[nfibs] = nnz;
    }

    /*########################################################################
    #   Descriptipn:    Construct the sparsity structure of the outer-mode
    #                   of a CSF tensor
    #
    #   Parameters:     ct (splatt_csf):        The CSF tensor to construct
    #                   tt (sptensor_t):        The sparse tensor (sorted)
    #                   tile_id (int):          The ID of the tile to make
    #                   nnztile_ptr (int []):   A pointer into 'tt' that marks
    #                                           the start of each tile.
    #
    #   Return:         None
    ########################################################################*/
    private proc p_mk_outerptr(ct : splatt_csf, tt : sptensor_t, tile_id : int, nnztile_ptr)
    {
        var nnzstart : int = nnztile_ptr[tile_id];
        var nnzend : int = nnztile_ptr[tile_id+1];
        var nnz : int = nnzend - nnzstart;
        assert(nnzstart < nnzend);
    
        // the mode after accounting for dim_perm
        // Get a c ptr to it to make this easier
        var indPtr = c_ptrTo(tt.ind[ct.dim_perm[0],0..ct.nnz-1]);
        var ttind = indPtr + nnzstart;

        // count fibers
        var nfibs : int = 1;
        for x in 1..nnz-1 {
            assert(ttind[x-1] <= ttind[x]);
            if ttind[x] != ttind[x-1] {
                nfibs += 1;
            }
        }
        ct.pt[tile_id].nfibs[0] = nfibs;
        assert(nfibs <= ct.dims[ct.dim_perm[0]]);

        // grab sparsity pattern
        var pt = ct.pt[tile_id];
        
        // Resize this mode's (0) subtree size and fiber ids size
        pt.fptr[0].subtree_d = 0..(nfibs+1)-1;
        pt.fids[0].fiber_ids_d = 0..nfibs-1;

        var fpPtr = c_ptrTo(pt.fptr[0].subtree);
        var fiPtr = c_ptrTo(pt.fids[0].fiber_ids);
        if ct.ntiles <= 1 {
            fiPtr = nil;
        }
        fpPtr[0] = 0;
        if fiPtr != nil {
            fiPtr[0] = ttind[0];
        }

        var nfound : int = 1;
        for n in 1..nnz-1 {
            // check for end of outer index
            if ttind[n] != ttind[n-1] {
                if fiPtr != nil {
                    fiPtr[nfound] = ttind[n];
                }
                fpPtr[nfound] = n;
                nfound += 1;
            }
        }
        fpPtr[nfibs] = nnz;
    }
}




