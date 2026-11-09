#!/bin/bash

# Load Intel compilers
module load intel/compilers-rt-2025.0.4
module load intel/tbb-2022.0
module load intel/umf-0.9.1
module load intel/compilers-2025.0.4

# Set up user-space libraries
export PATH=/projects/schultz/d.sasaki/compilation/explorer/20250720_trying_archi/libraries//bin:$PATH
export LD_LIBRARY_PATH=/projects/schultz/d.sasaki/compilation/explorer/20250720_trying_archi/libraries//lib:$LD_LIBRARY_PATH
export PKG_CONFIG_PATH=/projects/schultz/d.sasaki/compilation/explorer/20250720_trying_archi/libraries//lib/pkgconfig:$PKG_CONFIG_PATH
export CPATH=/projects/schultz/d.sasaki/compilation/explorer/20250720_trying_archi/libraries//include:$CPATH

# Intel runtime libraries (essential for Intel-compiled binaries)
export INTEL_ROOT=$(dirname $(dirname $(which icx)))
export LD_LIBRARY_PATH=$INTEL_ROOT/lib:$LD_LIBRARY_PATH

# MPI compiler wrappers
export MPICC=/projects/schultz/d.sasaki/compilation/explorer/20250720_trying_archi/libraries//bin/mpicc
export MPICXX=/projects/schultz/d.sasaki/compilation/explorer/20250720_trying_archi/libraries//bin/mpicxx
export MPIFC=/projects/schultz/d.sasaki/compilation/explorer/20250720_trying_archi/libraries//bin/mpifort
export MPIF77=/projects/schultz/d.sasaki/compilation/explorer/20250720_trying_archi/libraries//bin/mpif77
export MPIF90=/projects/schultz/d.sasaki/compilation/explorer/20250720_trying_archi/libraries//bin/mpif90

# Optimal UCX runtime settings for ConnectX-5
export UCX_NET_DEVICES=mlx5_0:1
export UCX_TLS=rc_mlx5,ud_mlx5,self,sm
export UCX_IB_REG_METHODS=rcache
export UCX_RNDV_THRESH=8192
export OMPI_MCA_pml=ucx
export OMPI_MCA_osc=ucx
export OMPI_MCA_btl=^vader,tcp,openib,uct

export UCX_LOG_LEVEL=warn
export OMPI_MCA_mca_verbose=100

export OMPI_MCA_coll_han_reproducible=true
export OMPI_MCA_coll_han_use_allreduce_algorithm=reproducible
export OMPI_MCA_coll_han_use_reduce_algorithm=reproducible

# Main condition test
# OpenMPI runtime settings for optimal performance
#export OMPI_MCA_pml=ucx
#export OMPI_MCA_osc=ucx
#export OMPI_MCA_btl=^vader,tcp,openib,uct

#export OMPI_MCA_pml=ob1
#export OMPI_MCA_btl=openib,vader,self

#ucx_info -d 2>/dev/null | grep -q "mlx\|ib_verbs\|rc_verbs"
#if [ $? -eq 0 ]; then
#    echo "Using UCX/InfiniBand"
#    export OMPI_MCA_pml=ucx
#else
#    echo "Using TCP (no InfiniBand detected)"
#    export OMPI_MCA_pml=ob1
#    export OMPI_MCA_btl=self,vader,tcp
#fi
