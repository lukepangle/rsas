# cython: profile=True
# -*- coding: utf-8 -*-
"""
.. module:: rsas
   :platform: Unix, Windows
   :synopsis: Time-variable transport using storage selection (SAS) functions

.. moduleauthor:: Ciaran J. Harman
"""

from __future__ import division
import cython
import numpy as np
cimport numpy as np
from warnings import warn
dtype = np.float64
ctypedef np.float64_t dtype_t
ctypedef np.int_t inttype_t
ctypedef np.long_t longtype_t
cdef inline np.float64_t float64_max(np.float64_t a, np.float64_t b): return a if a >= b else b
cdef inline np.float64_t float64_min(np.float64_t a, np.float64_t b): return a if a <= b else b
from _rsas_functions import rSASFunctionClass
from scipy.special import gamma as gamma_function
from scipy.special import gammainc
from scipy.special import erfc
from scipy.interpolate import interp1d
from scipy.optimize import fmin, minimize_scalar, fsolve
import time        
import _util

# for debugging
debug = True
def _verbose(statement):
    """Prints debuging messages if rsas.debug==True
    
    """
    if debug:
        print statement
        
def solve(J, Q, rSAS_fun, mode='time', ST_init = None, dt = 1, n_substeps = 1, 
          n_iterations = 3, full_outputs=True, C_in=None, C_old=None, evapoconcentration=False):
    """Solve the rSAS model for given fluxes

    Args: 
        J : n x 1 float64 ndarray
            Timestep-averaged inflow timeseries
        Q : n x 2 float64 ndarray or list of n x 1 float64 ndarray
            Timestep-averaged outflow timeseries. Must have same units and length as J.
            For multiple outflows, each column represents one outflow
        rSAS_fun : rSASFunctionClass or list of rSASFunctionClass generated by rsas.create_function
            The number of rSASFunctionClass in this list must be the same as the 
            number of columns in Q if Q is an ndarray, or elements in Q if it is a list.

    Kwargs:
        mode : 'age' or 'time' (default)
            Numerical solution step order. 'mode' refers to which variable is in the
            outer loop of the numerical solution
            
            ``mode='age'``
                This is the original implementation used to generate the results in the paper.
                It is slightly faster than the 'time' implementation, but doesn't have the
                memory-saving "full_outputs=False" option. There is no option to calculate 
                output concentration timeseries inline. The calculated transit time
                distributions must convolved with an input concentration timeseries after the code has 
                completed.
            ``mode='time'``
                Slower, but easier to understand and build on than the 'age' mode.
                Memory savings come with the option to determine output concentrations
                from a given input concentration progressively, and not retain the full
                age-ranked storage and transit time distributions in memory (set
                full_outputs=False to take advantage of this).
        ST_init : m x 1 float64 ndarray
            Initial condition for the age-ranked storage. The length of ST_init
            determines the maximum age calculated. The first entry must be 0
            (corresponding to zero age). To calculate transit time dsitributions up
            to N timesteps in age, ST_init should have length m = M + 1. The default
            initial condition is ST_init=np.zeros(len(J) + 1).
        dt : float (default 1)
            Timestep, assuming same units as J
        n_substeps : int (default 1)
            (mode='age' only) If n_substeps>1, the timesteps are subdivided to allow a more accurate
            solution. Default is 1, which is also the value used in Harman (2015)
        n_iterations : int (default 3)
            Number of iterations to converge on a consistent solution. Convergence 
            in Harman (2015) was very fast, and n_iterations=3 was adequate (also 
            the default value here)
        full_outputs : bool (default True)
            (mode='time' only) Option to return the full state variables array ST the cumulative
            transit time distributions PQ1, PQ2, and other variables
        C_in : n x 1 float64 ndarray (default None)
            Optional timeseries of inflow concentrations to convolved
            with the computed transit time distribution for the first flux in Q
        C_old : float (default None)
            Optional concentration of the 'unobserved fraction' of Q (from inflows 
            prior to the start of the simulation) for correcting C_out. If ST_init is not given 
            or set to all zeros, the unobserved fraction will be assumed to lie on the 
            diagonal of the PQ matrix. Otherwise it will be assumed to be the bottom row.
        evapoconcentration : bool (default False)
            If True, it will be assumed that species in C_in are not removed 
            by the second flux, and instead become increasingly concentrated in
            storage.

    
    
    Returns:
        A dict with the following keys:
            'ST' : numpy float64 2D array
                Array of age-ranked storage for all ages and times. (full_outputs=True only)
            'PQ' : numpy float64 2D array
                List of time-varying cumulative transit time distributions. (full_outputs=True only)
            'Qout' : numpy float64 2D array
                List of age-based outflow timeseries. Useful for visualization. (full_outputs=True only)
            'theta' : numpy float64 2D array
                List of partial partition functions for each outflux. Keeps track of the
                fraction of inputs that leave by each flux. This is needed to do
                transport with evapoconcentration. (full_outputs=True only)
            'thetaS' : numpy float64 2D array
                Storage partial partition function fr each outflux. Keeps track of the
                fraction of inputs that remain in storage. This is needed to do
                transport with evapoconcentration. (full_outputs=True only)
            'MassBalance' : numpy float64 2D array
                Should always be within tolerances of zero, unless something is very
                wrong. (full_outputs=True only)
            'C_out' : list of numpy float64 1D array
                If C_in is supplied, C_out is the timeseries of outflow concentration 
                in Q1. (mode='time' only)

    For each of the arrays in the full outputs each row represents an age, and each
    column is a timestep. For N timesteps and M ages, ST will have dimensions
    (M+1) x (N+1), with the first row representing age T = 0 and the first
    column derived from the initial condition.
    """
    # This function just does input checking
    # then calls the private implementation functions defined below
    if type(J) is not np.ndarray or J.ndim!=1:
        raise TypeError('J must be a 1-D numpy array')
    if type(Q) is np.ndarray:
        if Q.ndim==1:
            Q=[Q]
        else:
            Q = [Q[:,i] for i in Q.shape[1]]
    for Qi in Q:
        if type(Qi) is not np.ndarray or Qi.ndim!=1 or len(Qi)!=len(J):
            raise TypeError('Q must be a 2-D numpy array with a column for each outflow\nor a list of two 1-D numpy arrays (like ''[Q1, Q2]'')\nand each must be the same size as J')
    if ST_init is not None:
        if type(ST_init) is not np.ndarray or ST_init.ndim!=1:
            raise TypeError('ST_init must be a 1-D numpy array')
    if not type(rSAS_fun) is list:
        rSAS_fun = [rSAS_fun]
    if len(Q)!=len(rSAS_fun):
        raise TypeError('Each rSAS function must have a corresponding outflow in Q. Numbers don''t match')
    for fun in rSAS_fun:
        fun_methods = [method for method in dir(fun) if callable(getattr(fun, method))]
        if not ('cdf_all' in fun_methods and 'cdf_i' in fun_methods):
            raise TypeError('Each rSAS function must have methods rSAS_fun.cdf_all and rSAS_fun.cdf_i')
    if type(full_outputs) is not bool:
        raise TypeError('full_outputs must be a boolean (True/False)')
    if type(evapoconcentration) is not bool:
        raise TypeError('evapoconcentration must be a boolean (True/False)')
    if C_in is not None and (type(C_in) is not np.ndarray or C_in.ndim!=1 or len(C_in)!=len(J)):
        raise TypeError('C_in must be a 1-D numpy array the same length as J')
    if C_old is not None:
        C_old = np.float64(C_old)
    if dt is not None:
        dt = np.float64(dt)
    if n_substeps is not None:
        n_substeps = np.int(n_substeps)
    if n_iterations is not None:
        n_iterations = np.int(n_iterations)
    if full_outputs==False and C_in is None:
        warn('No output will be generated! Are you sure you mean to do this?')
    # Run implemented solvers
    if mode=='age':
        if C_in is not None:
            C_in = None
            warn('C_in not compatible with mode==''age''. Convolution must be done separately')
        if len(Q)==1:
            result = _solve_all_by_age_1out(J, Q[0], rSAS_fun[0], 
                                          ST_init=ST_init, dt=dt,
                                          n_substeps=n_substeps, n_iterations=n_iterations, C_in=C_in, C_old=C_old)
        elif len(Q)==2:
            result = _solve_all_by_age_2out(J, Q[0], rSAS_fun[0], Q[1], rSAS_fun[1], 
                                          ST_init=ST_init, dt=dt,
                                          n_substeps=n_substeps, n_iterations=n_iterations, C_in=C_in, 
                                          C_old=C_old, evapoconcentration=evapoconcentration)
        else:
            raise NotImplementedError('mode==''age'' only implemented for 1 or 2 outflows.')
    elif mode=='time':
        if len(Q)==1:
            result = _solve_all_by_time_1out(J, Q[0], rSAS_fun[0],
                                              ST_init = ST_init, dt = dt, n_iterations=n_iterations,
                                              full_outputs=full_outputs, C_in=C_in, C_old=C_old)
        elif len(Q)==2:
            result = _solve_all_by_time_2out(J, Q[0], rSAS_fun[0], Q[1], rSAS_fun[1], 
                                          ST_init=ST_init, dt=dt, n_iterations=n_iterations,
                                          full_outputs=full_outputs, C_in=C_in,
                                          C_old=C_old, evapoconcentration=evapoconcentration)
        else:
            raise NotImplementedError('mode==''time'' only implemented for 1 or 2 outflows.')
    else:
        raise TypeError('Incorrect solution mode. Must be ''age'' or ''time''')
    # handle the output
    if full_outputs:
        if C_in is None:
            if len(Q)==1:
                ST, PQ1, Q1out, theta1, thetaS, MassBalance = result
                output = {'ST':ST, 'PQ':[PQ1], 'Qout':[Q1out], 'thetaQ':[theta1], 'thetaS':thetaS, 'MassBalance':MassBalance}
            elif len(Q)==2:
                ST, PQ1, PQ2, Q1out, Q2out, theta1, theta2, thetaS, MassBalance = result
                output = {'ST':ST, 'PQ':[PQ1, PQ2], 'Qout':[Q1out, Q2out], 'thetaQ':[theta1, theta2], 'thetaS':thetaS, 'MassBalance':MassBalance}
        else:
            if len(Q)==1:
                C_out, ST, PQ1, Q1out, theta1, thetaS, MassBalance = result
                output = {'ST':ST, 'PQ':[PQ1], 'Qout':[Q1out], 'thetaQ':[theta1], 'thetaS':thetaS, 'MassBalance':MassBalance, 'C_out':[C_out]}
            elif len(Q)==2:
                C_out, ST, PQ1, PQ2, Q1out, Q2out, theta1, theta2, thetaS, MassBalance = result
                output = {'ST':ST, 'PQ':[PQ1, PQ2], 'Qout':[Q1out, Q2out], 'thetaQ':[theta1, theta2], 'thetaS':thetaS, 'MassBalance':MassBalance, 'C_out':[C_out]}
    else:
        C_out = result
        output = {'C_out':[C_out]}
    return output


@cython.boundscheck(False)
@cython.wraparound(False)
def _solve_all_by_age_2out(
        np.ndarray[dtype_t, ndim=1] J, 
        np.ndarray[dtype_t, ndim=1] Q1, 
        rSAS_fun1,
        np.ndarray[dtype_t, ndim=1] Q2, 
        rSAS_fun2,
        np.ndarray[dtype_t, ndim=1] ST_init = None, 
        dtype_t dt = 1, 
        int n_substeps = 1, 
        int n_iterations = 3,
        full_outputs=True, C_in=None, C_old=None, evapoconcentration=False):
    """Private function solving the rSAS model with 2 outflows, solved using the original age-based algorithm

    See the docstring for rsas.solve for moreinformation
    """
    # Initialization
    # Define some variables
    cdef int k, i, timeseries_length, num_inputs, max_age, N
    cdef np.float64_t start_time
    cdef np.ndarray[dtype_t, ndim=2] ST, PQ1, PQ2, Q1out, Q2out, theta1, theta2, thetaS, MassBalance
    cdef np.ndarray[dtype_t, ndim=1] STp, PQ1p, PQ2p, Q1outp, Q2outp
    cdef np.ndarray[dtype_t, ndim=1] STu, PQ1u, PQ2u, dPQ1u, dPQ2u, dQ1outu, dQ2outu, dSTp, dPQ1p, dPQ2p
    cdef np.ndarray[dtype_t, ndim=1] Q1r, Q2r, Jr
    #cdef np.ndarray[dtype_t, ndim=2] Q1_paramsr, Q2_paramsr
    # Handle inputs
    if ST_init is None:
        ST_init=np.zeros(len(J) + 1)
    else:
        # This must be true
        ST_init[0] = 0
    # Some lengths
    timeseries_length = len(J)
    max_age = len(ST_init) - 1
    N = timeseries_length * n_substeps
    # Expand the inputs to accomodate the substep solution points
    Q1r = Q1.repeat(n_substeps)
    Q2r = Q2.repeat(n_substeps)
    Jr = J.repeat(n_substeps)
    dt = dt / n_substeps
    # Create arrays to hold the state variables
    _verbose('...initializing arrays...')
    ST = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    PQ1 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    PQ2 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    Q1out = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    Q2out = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    theta1 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    theta2 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    thetaS = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    MassBalance = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    #Create arrays to hold intermediate solutions
    STp = np.zeros(N+1, dtype=np.float64)
    PQ1p = np.zeros(N+1, dtype=np.float64)
    PQ2p = np.zeros(N+1, dtype=np.float64)
    Q1outp = np.zeros(N+1, dtype=np.float64)
    Q2outp = np.zeros(N+1, dtype=np.float64)
    dSTp = np.zeros(N, dtype=np.float64)
    dPQ1p = np.zeros(N, dtype=np.float64)
    dPQ2p = np.zeros(N, dtype=np.float64)
    dSTu = np.zeros(N, dtype=np.float64)
    dPQ1u = np.zeros(N, dtype=np.float64)
    dPQ2u = np.zeros(N, dtype=np.float64)
    STu = np.zeros(N, dtype=np.float64)
    PQ1u = np.zeros(N, dtype=np.float64)
    PQ2u = np.zeros(N, dtype=np.float64)
    dQ1outu = np.zeros(N, dtype=np.float64)
    dQ2outu = np.zeros(N, dtype=np.float64)
    _verbose('done')
    # Now we solve the governing equation
    # Set up initial and boundary conditions
    dSTp[:] = Jr * dt
    dPQ1p[:] = np.where(dSTp>0., rSAS_fun1.cdf_all(dSTp), 0.)
    dPQ2p[:] = np.where(dSTp>0., rSAS_fun2.cdf_all(dSTp), 0.)
    ST[:, 0] = ST_init[:]
    PQ1_init = rSAS_fun1.cdf_i(ST_init, 0)
    PQ2_init = rSAS_fun2.cdf_i(ST_init, 0)
    PQ1[:, 0] = PQ1_init
    PQ2[:, 0] = PQ2_init
    start_time = time.clock()
    _verbose('...solving...')
    # Primary solution loop over ages T
    for i in range(max_age):
    # Loop over substeps
        for k in range(n_substeps):
            # dSTp is the increment of ST at the previous age and previous timestep.
            # It is therefore our first estimate of the increment of ST at this
            # age and timestep. 
            STu[:] = STp[1:] + dSTp
            # Use this estimate to get an initial estimate of the 
            # cumulative transit time distributions, PQ1 and PQ2
            PQ1u[:] = np.where(dSTp>0., rSAS_fun1.cdf_all(STu), PQ1p[1:])
            PQ2u[:] = np.where(dSTp>0., rSAS_fun2.cdf_all(STu), PQ2p[1:])
            # Iterate to refine these estimates
            for it in range(n_iterations):
                # Increments of the cumulative transit time distribution
                # approximate the values of the transit time PDF at this age
                dPQ1u[:] = (PQ1u - PQ1p[1:])
                dPQ2u[:] = (PQ2u - PQ2p[1:])
                # Estimate the outflow over the interval of ages dt with an age
                # T as the discharge over the timestep times the average of the
                # PDF values at the start and the end of the timestep
                dQ1outu[:] = Q1r * (dPQ1u + dPQ1p) / 2
                dQ2outu[:] = Q2r * (dPQ2u + dPQ2p) / 2
                # Update the estimate of dST, ST and the cumulative TTD to
                # account for these outflows
                dSTu[:] = np.maximum(dSTp - dt * dQ1outu - dt * dQ2outu, 0.)
                STu[:] = STp[1:] + dSTu
                PQ1u[:] = np.where(dSTp>0., rSAS_fun1.cdf_all(STu), PQ1p[1:])
                PQ2u[:] = np.where(dSTp>0., rSAS_fun2.cdf_all(STu), PQ2p[1:])
            # Update the 'previous solution' record in preparation of the
            # next solution timestep
            STp[1:] = STu[:]
            PQ1p[1:] = PQ1u[:]
            PQ2p[1:] = PQ2u[:]
            dSTp[1:]  = dSTu[:N-1]
            dPQ1p[1:] = dPQ1u[:N-1]
            dPQ2p[1:] = dPQ2u[:N-1]
            # Incorporate the boundary condition
            dSTp[0]  = (ST_init[i+1] - (ST_init[i])) / n_substeps
            dPQ1p[0] = (PQ1_init[i+1] - (PQ1_init[i])) / n_substeps
            dPQ2p[0] = (PQ2_init[i+1] - (PQ2_init[i])) / n_substeps
            # Keep a running tally of the outflows by age
            Q1outp[1:] = Q1outp[:N] + dQ1outu[:]
            Q2outp[1:] = Q2outp[:N] + dQ2outu[:]
            Q1out[i+1, 1:] += Q1outp[n_substeps::n_substeps]/n_substeps
            Q2out[i+1, 1:] += Q2outp[n_substeps::n_substeps]/n_substeps
            # If a full timestep is complete, store the result
            if k==n_substeps-1:
                ST[i+1, 1:] =   STp[n_substeps::n_substeps]
                PQ1[i+1, 1:] = PQ1p[n_substeps::n_substeps]
                PQ2[i+1, 1:] = PQ2p[n_substeps::n_substeps]
                theta1[i+1, i+1:] = np.where(J[:timeseries_length-i]>0, Q1out[i+1, i+1:] / J[:timeseries_length-i], 0.)
                theta2[i+1, i+1:] = np.where(J[:timeseries_length-i]>0, Q2out[i+1, i+1:] / J[:timeseries_length-i], 0.) 
                thetaS[i+1, i+1:] = np.where(J[:timeseries_length-i]>0, (ST[i+1, i+1:] - ST[i, i+1:]) / J[:timeseries_length-i], 0.)
                MassBalance[i+1, i+1:] = (J[:timeseries_length-i] 
                                        - Q1out[i+1, i+1:] - Q2out[i+1, i+1:] 
                                        - (ST[i+1, i+1:] - ST[i, i+1:])/dt)
        if np.mod(i+1,1000)==0:
            _verbose('...done ' + str(i+1) + ' of ' + str(max_age) + ' in ' + str(time.clock() - start_time) + ' seconds')
    # Evaluation of outflow concentration
    if C_in is not None:
        if evapoconcentration:
            C_out, _, observed_fraction = _util.transport_with_evapoconcentration(PQ1, theta1, thetaS, C_in, C_old)
        else:
            C_out, _, observed_fraction = _util.transport(PQ1, theta1, thetaS, C_in, C_old)
        return C_out, ST, PQ1, PQ2, Q1out, Q2out, theta1, theta2, thetaS, MassBalance        
    else:
        return ST, PQ1, PQ2, Q1out, Q2out, theta1, theta2, thetaS, MassBalance        
        

@cython.boundscheck(False)
@cython.wraparound(False)
def _solve_all_by_age_1out(
        np.ndarray[dtype_t, ndim=1] J, 
        np.ndarray[dtype_t, ndim=1] Q1, 
        rSAS_fun1,
        np.ndarray[dtype_t, ndim=1] ST_init = None, 
        dtype_t dt = 1, 
        int n_substeps = 1, 
        int n_iterations = 3, C_in=None, C_old=None):
    """Private function solving the rSAS model with 2 outflows, solved using the original age-based algorithm

    See the docstring for rsas.solve for moreinformation
    """
    # Initialization
    # Define some variables
    cdef int k, i, timeseries_length, num_inputs, max_age, N
    cdef np.float64_t start_time
    cdef np.ndarray[dtype_t, ndim=2] ST, PQ1, Q1out, theta1, thetaS, MassBalance
    cdef np.ndarray[dtype_t, ndim=1] STp, PQ1p, Q1outp
    cdef np.ndarray[dtype_t, ndim=1] STu, PQ1u, dPQ1u, dQ1outu, dSTp, dPQ1p
    cdef np.ndarray[dtype_t, ndim=1] Q1r, Jr
    #cdef np.ndarray[dtype_t, ndim=2] Q1_paramsr, Q2_paramsr
    # Handle inputs
    if ST_init is None:
        ST_init=np.zeros(len(J) + 1)
    else:
        # This must be true
        ST_init[0] = 0
    # Some lengths
    timeseries_length = len(J)
    max_age = len(ST_init) - 1
    N = timeseries_length * n_substeps
    # Expand the inputs to accomodate the substep solution points
    Q1r = Q1.repeat(n_substeps)
    Jr = J.repeat(n_substeps)
    dt = dt / n_substeps
    # Create arrays to hold the state variables
    _verbose('...initializing arrays...')
    ST = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    PQ1 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    Q1out = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    theta1 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    thetaS = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    MassBalance = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    #Create arrays to hold intermediate solutions
    STp = np.zeros(N+1, dtype=np.float64)
    PQ1p = np.zeros(N+1, dtype=np.float64)
    Q1outp = np.zeros(N+1, dtype=np.float64)
    dSTp = np.zeros(N, dtype=np.float64)
    dPQ1p = np.zeros(N, dtype=np.float64)
    dSTu = np.zeros(N, dtype=np.float64)
    dPQ1u = np.zeros(N, dtype=np.float64)
    STu = np.zeros(N, dtype=np.float64)
    PQ1u = np.zeros(N, dtype=np.float64)
    dQ1outu = np.zeros(N, dtype=np.float64)
    _verbose('done')
    # Now we solve the governing equation
    # Set up initial and boundary conditions
    dSTp[:] = Jr * dt
    dPQ1p[:] = np.where(dSTp>0., rSAS_fun1.cdf_all(dSTp), 0.)
    ST[:, 0] = ST_init[:]
    PQ1_init = rSAS_fun1.cdf_i(ST_init, 0)
    PQ1[:, 0] = PQ1_init
    start_time = time.clock()
    _verbose('...solving...')
    # Primary solution loop over ages T
    for i in range(max_age):
    # Loop over substeps
        for k in range(n_substeps):
            # dSTp is the increment of ST at the previous age and previous timestep.
            # It is therefore our first estimate of the increment of ST at this
            # age and timestep. 
            STu[:] = STp[1:] + dSTp
            # Use this estimate to get an initial estimate of the 
            # cumulative transit time distributions, PQ1 and PQ2
            PQ1u[:] = np.where(dSTp>0., rSAS_fun1.cdf_all(STu), PQ1p[1:])
            # Iterate to refine these estimates
            for it in range(n_iterations):
                # Increments of the cumulative transit time distribution
                # approximate the values of the transit time PDF at this age
                dPQ1u[:] = (PQ1u - PQ1p[1:])
                # Estimate the outflow over the interval of ages dt with an age
                # T as the discharge over the timestep times the average of the
                # PDF values at the start and the end of the timestep
                dQ1outu[:] = Q1r * (dPQ1u + dPQ1p) / 2
                # Update the estimate of dST, ST and the cumulative TTD to
                # account for these outflows
                dSTu[:] = np.maximum(dSTp - dt * dQ1outu, 0.)
                STu[:] = STp[1:] + dSTu
                PQ1u[:] = np.where(dSTp>0., rSAS_fun1.cdf_all(STu), PQ1p[1:])
            # Update the 'previous solution' record in preparation of the
            # next solution timestep
            STp[1:] = STu[:]
            PQ1p[1:] = PQ1u[:]
            dSTp[1:]  = dSTu[:N-1]
            dPQ1p[1:] = dPQ1u[:N-1]
            # Incorporate the boundary condition
            dSTp[0]  = (ST_init[i+1] - (ST_init[i])) / n_substeps
            dPQ1p[0] = (PQ1_init[i+1] - (PQ1_init[i])) / n_substeps
            # Keep a running tally of the outflows by age
            Q1outp[1:] = Q1outp[:N] + dQ1outu[:]
            Q1out[i+1, 1:] += Q1outp[n_substeps::n_substeps]/n_substeps
            # If a full timestep is complete, store the result
            if k==n_substeps-1:
                ST[i+1, 1:] =   STp[n_substeps::n_substeps]
                PQ1[i+1, 1:] = PQ1p[n_substeps::n_substeps]
                theta1[i+1, i+1:] = np.where(J[:timeseries_length-i]>0, Q1out[i+1, i+1:] / J[:timeseries_length-i], 0.)
                thetaS[i+1, i+1:] = np.where(J[:timeseries_length-i]>0, (ST[i+1, i+1:] - ST[i, i+1:]) / J[:timeseries_length-i], 0.)
                MassBalance[i+1, i+1:] = (J[:timeseries_length-i] 
                                        - Q1out[i+1, i+1:] 
                                        - (ST[i+1, i+1:] - ST[i, i+1:])/dt)
        if np.mod(i+1,1000)==0:
            _verbose('...done ' + str(i+1) + ' of ' + str(max_age) + ' in ' + str(time.clock() - start_time) + ' seconds')
    # Evaluation of outflow concentration
    if C_in is not None:
        C_out, _, observed_fraction = _util.transport(PQ1, theta1, thetaS, C_in, C_old)
        return C_out, ST, PQ1, Q1out, theta1, thetaS, MassBalance
    else:
        return ST, PQ1, Q1out, theta1, thetaS, MassBalance


@cython.boundscheck(False)
@cython.wraparound(False)
def _solve_all_by_time_2out(np.ndarray[dtype_t, ndim=1] J, 
        np.ndarray[dtype_t, ndim=1] Q1, 
        rSAS_fun1,
        np.ndarray[dtype_t, ndim=1] Q2, 
        rSAS_fun2,
        np.ndarray[dtype_t, ndim=1] ST_init = None, 
        dtype_t dt = 1, 
        int n_iterations = 3,
        full_outputs=True, C_in=None, C_old=None, evapoconcentration=False):
    """rSAS model with 2 outfluxes, solved by looping over timesteps.

    See the docstring for rsas.solve for more information
    """
    # Initialization
    # Define some variables
    cdef int k, i, timeseries_length, num_inputs, max_age
    cdef np.float64_t start_time
    cdef np.ndarray[dtype_t, ndim=2] ST, PQ1, PQ2, Q1out, Q2out, theta1, theta2, thetaS, MassBalance
    cdef np.ndarray[dtype_t, ndim=1] STu, pQ1u, pQ2u, pQ1p, pQ2p, dQ1outu, dQ2outu, dSTu, dSTp, C_out, Q1out_total
    # Handle inputs
    if ST_init is None:
        ST_init=np.zeros(len(J) + 1)
    else:
        # This must be true
        ST_init[0] = 0
    # Some lengths
    timeseries_length = len(J)
    max_age = len(ST_init) - 1
    # Create arrays to hold intermediate solutions
    _verbose('...initializing arrays...')
    pQ1p = np.zeros(max_age, dtype=np.float64)
    pQ2p = np.zeros(max_age, dtype=np.float64)
    STu = np.zeros(max_age+1, dtype=np.float64)
    dQ1outu = np.zeros(max_age, dtype=np.float64)
    dQ2outu = np.zeros(max_age, dtype=np.float64)
    pQ1u = np.zeros(max_age, dtype=np.float64)
    pQ2u = np.zeros(max_age, dtype=np.float64)
    dSTu = np.zeros(max_age, dtype=np.float64)
    dSTp = np.zeros(max_age, dtype=np.float64)
    if C_in is not None:
        if evapoconcentration:
            Q1out_total = np.zeros((max_age), dtype=np.float64)
        C_out = np.zeros(max_age, dtype=np.float64)
    # Create arrays to hold the state variables if they are to be outputted
    if full_outputs:
        ST = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        PQ1 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        PQ2 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        Q1out = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        Q2out = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        theta1 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        theta2 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        thetaS = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        MassBalance = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    _verbose('done')
    # Now we solve the governing equation
    # Set up initial and boundary conditions
    dSTp[0] = J[0] * dt
    dSTp[1:max_age] = np.diff(ST_init[:max_age])
    pQ1p[:] = np.diff(rSAS_fun1.cdf_i(ST_init, 0))
    pQ2p[:] = np.diff(rSAS_fun2.cdf_i(ST_init, 0))
    if full_outputs:
        ST[:,0] = ST_init[:]
        PQ1[:,0] = rSAS_fun1.cdf_i(ST_init, 0)
        PQ2[:,0] = rSAS_fun2.cdf_i(ST_init, 0)
    start_time = time.clock()
    _verbose('...solving...')
    # Primary solution loop over time t
    for i in range(timeseries_length):
        # dSTp is the increments of ST at the previous age and previous timestep.
        # It is therefore our first estimate of the increments of ST at this
        # age and timestep. Add up the increments to get an estimate of ST
        STu[0] = 0
        STu[1:max_age+1] = np.cumsum(dSTp)
        # Use this estimate to get an initial estimate of the 
        # transit time distribution PDFs, pQ1 and pQ2
        pQ1u[:max_age] = np.diff(rSAS_fun1.cdf_i(STu, i))
        pQ2u[:max_age] = np.diff(rSAS_fun2.cdf_i(STu, i))
        # Iterate to refine these estimates
        for it in range(n_iterations):
            # Estimate the outflow over the interval of time dt with an age
            # T as the discharge over the timestep times the average of the
            # PDF values at the start and the end of the timestep
            dQ1outu[0] = Q1[i] * pQ1u[0]
            dQ1outu[1:max_age] = Q1[i] * (pQ1u[1:max_age] + pQ1p[1:max_age])/2
            dQ2outu[0] = Q2[i] * pQ2u[0]
            dQ2outu[1:max_age] = Q2[i] * (pQ2u[1:max_age] + pQ2p[1:max_age])/2
            # Update the estimate of dST, ST and the TTD PDFs to
            # account for these outflows
            dSTu[:max_age] = np.maximum(dSTp - dt * dQ1outu - dt * dQ2outu, 0.)
            STu[1:max_age+1] = np.cumsum(dSTu)
            pQ1u[:max_age] = np.diff(rSAS_fun1.cdf_i(STu, i))
            pQ2u[:max_age] = np.diff(rSAS_fun2.cdf_i(STu, i))
        # Update the 'previous solution' record in preparation of the
        # next solution timestep
        if i<timeseries_length-1:
            dSTp[1:max_age] = dSTu[:max_age-1]
            # Incorporate the boundary condition
            dSTp[0] = J[i+1] * dt
            pQ1p[1:max_age] = pQ1u[:max_age-1]
            pQ2p[1:max_age] = pQ2u[:max_age-1]
            pQ1p[0] = 0
            pQ2p[0] = 0
        # Progressive evaluation of outflow concentration
        if C_in is not None:
            if evapoconcentration:
                # If evapoconcentration=True, keep a running tab of how much of
                # each timestep's inflow has become outflow
                Q1out_total[:i+1] = Q1out_total[:i+1] + dQ1outu[i::-1]
                # The enriched concentration in storge is the initial mass
                # divided by the volume that has not evaporated 
                # C_in * J / (Q1out_total + dSTu)
                # Get the current discharge concentration as the sum of previous
                # (weighted) inputs, accounting for evapoconcentration
                C_out[i] = np.sum(np.where(J[i::-1]>0, pQ1u[:i+1] * C_in[i::-1] * J[i::-1] / (Q1out_total[i::-1] + dSTu[:i+1]), 0.))
            else:
                # Get the current discharge concentration as the sum of previous
                # (weighted) inputs
                C_out[i] = np.sum(pQ1u[:i+1] * C_in[i::-1])
            if C_old:
                # Add the concentration of the 'unobserved fraction'
                C_out[i] += (1 - np.sum(pQ1u[:i+1])) * C_old
        # Store the result, if needed
        if full_outputs:
            ST[:max_age+1, i+1] =   STu[:max_age+1]
            PQ1[1:max_age+1, i+1] = np.cumsum(pQ1u)
            PQ2[1:max_age+1, i+1] = np.cumsum(pQ2u)
            Q1out[1:max_age+1, i+1] = Q1out[:max_age, i] + dQ1outu[:max_age]
            Q2out[1:max_age+1, i+1] = Q2out[:max_age, i] + dQ2outu[:max_age]
            theta1[1:i+2, i+1] = np.where(J[i::-1]>0, Q1out[1:i+2, i+1] / J[i::-1], 0.)
            theta2[1:i+2, i+1] = np.where(J[i::-1]>0, Q2out[1:i+2, i+1] / J[i::-1], 0.)
            thetaS[1:i+2, i+1] = np.where(J[i::-1]>0, (ST[1:i+2, i+1] - ST[:i+1, i+1]) / J[i::-1], 0.)
            MassBalance[1:i+2, i+1] = np.diff(ST[:i+2, i+1]) - dt * (J[i::-1] - Q1out[1:i+2, i+1] - Q2out[1:i+2, i+1])
            MassBalance[i+2:max_age+1, i+1] = np.diff(ST[i+1:max_age+1, i+1]) - dt * (np.diff(ST_init[:max_age-i]) - Q1out[i+2:max_age+1, i+1] - Q2out[i+2:max_age+1, i+1])
        if np.mod(i+1,1000)==0:
            _verbose('...done ' + str(i+1) + ' of ' + str(max_age) + ' in ' + str(time.clock() - start_time) + ' seconds')
    # Done. Return the outputs
    if full_outputs and C_in is not None:
        return C_out, ST, PQ1, PQ2, Q1out, Q2out, theta1, theta2, thetaS, MassBalance
    elif full_outputs and C_in is None:
        return ST, PQ1, PQ2, Q1out, Q2out, theta1, theta2, thetaS, MassBalance
    elif not full_outputs and C_in is not None:
        return C_out


@cython.boundscheck(False)
@cython.wraparound(False)
def _solve_all_by_time_1out(np.ndarray[dtype_t, ndim=1] J, 
        np.ndarray[dtype_t, ndim=1] Q1, 
        rSAS_fun1,
        np.ndarray[dtype_t, ndim=1] ST_init = None, 
        dtype_t dt = 1, 
        int n_iterations = 3,
        full_outputs=True, C_in=None, C_old=None):
    """rSAS model with 1 flux, solved by looping over timesteps.

    Same as solve_all_by_time_2out, but for only one flux out. 
    See the docstring for rsas.solve for more information
    """
    # Initialization
    # Define some variables
    cdef int k, i, timeseries_length, num_inputs, max_age
    cdef np.float64_t start_time
    cdef np.ndarray[dtype_t, ndim=2] ST, PQ1, Q1out, theta1, thetaS, MassBalance
    cdef np.ndarray[dtype_t, ndim=1] STu, pQ1u, pQ1p, dQ1outu, dSTu, dSTp, C_out
    # Handle inputs
    if ST_init is None:
        ST_init=np.zeros(len(J) + 1)
    else:
        # This must be true
        ST_init[0] = 0
    # Some lengths
    timeseries_length = len(J)
    max_age = len(ST_init) - 1
    # Create arrays to hold intermediate solutions
    _verbose('...initializing arrays...')
    pQ1p = np.zeros(max_age, dtype=np.float64)
    pQ2p = np.zeros(max_age, dtype=np.float64)
    STu = np.zeros(max_age+1, dtype=np.float64)
    dQ1outu = np.zeros(max_age, dtype=np.float64)
    dQ2outu = np.zeros(max_age, dtype=np.float64)
    pQ1u = np.zeros(max_age, dtype=np.float64)
    pQ2u = np.zeros(max_age, dtype=np.float64)
    dSTu = np.zeros(max_age, dtype=np.float64)
    dSTp = np.zeros(max_age, dtype=np.float64)
    if C_in is not None:
        C_out = np.zeros(max_age, dtype=np.float64)
    # Create arrays to hold the state variables if they are to be outputted
    if full_outputs:
        ST = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        PQ1 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        PQ2 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        Q1out = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        Q2out = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        theta1 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        theta2 = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        thetaS = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        MassBalance = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
    _verbose('done')
    # Now we solve the governing equation
    # Set up initial and boundary conditions
    dSTp[0] = J[0] * dt
    dSTp[1:max_age] = np.diff(ST_init[:max_age])
    pQ1p[:] = np.diff(rSAS_fun1.cdf_i(ST_init, 0))
    if full_outputs:
        ST[:,0] = ST_init[:]
        PQ1[:,0] = rSAS_fun1.cdf_i(ST_init, 0)
    start_time = time.clock()
    _verbose('...solving...')
    # Primary solution loop over time t
    for i in range(timeseries_length):
        # dSTp is the increments of ST at the previous age and previous timestep.
        # It is therefore our first estimate of the increments of ST at this
        # age and timestep. 
        STu[0]=0
        STu[1:max_age+1]=np.cumsum(dSTp)
        #Use this estimate to get an initial estimate of the 
        # transit time distribution PDF, pQ1
        pQ1u[0] = rSAS_fun1.cdf_i(dSTp[:1], i)
        pQ1u[1:max_age] = np.diff(rSAS_fun1.cdf_i(np.cumsum(dSTp), i))
        # Iterate to refine the estimates
        for it in range(n_iterations):
            # Estimate the outflow over the interval of time dt with an age
            # T as the discharge over the timestep times the average of the
            # PDF values at the start and the end of the timestep
            dQ1outu[0] = Q1[i] * pQ1u[0]
            dQ1outu[1:max_age] = Q1[i] * (pQ1u[1:max_age] + pQ1p[1:max_age])/2
            # Update the estimate of dST and the TTD PDF to
            # account for the outflow
            dSTu[:max_age] = np.maximum(dSTp - dt * dQ1outu - dt * dQ2outu, 0.)
            STu[1:max_age+1] = np.cumsum(dSTu) 
            pQ1u[0] = rSAS_fun1.cdf_i(dSTu[:1], i)
            pQ1u[1:max_age] = np.diff(rSAS_fun1.cdf_i(np.cumsum(dSTu), i))
        # Update the 'previous solution' record in preparation of the
        # next solution timestep
        if i<timeseries_length-1:
            dSTp[1:max_age] = dSTu[:max_age-1]
            pQ1p[1:max_age] = pQ1u[:max_age-1]
            # Incorporate the boundary condition
            dSTp[0] = J[i+1] * dt
            # This vale is never used
            pQ1p[0] = 0
        # Progressive evaluation of outflow concentration
        if C_in is not None:
            C_out[i] = np.sum(pQ1u[:i+1] * C_in[i::-1])
            if C_old:
                C_out[i] += (1 - np.sum(pQ1u[:i+1])) * C_old
        # Store the result, if needed
        if full_outputs:
            ST[:max_age+1, i+1] =   STu[:max_age+1]
            PQ1[1:max_age+1, i+1] = np.cumsum(pQ1u)
            Q1out[1:max_age+1, i+1] = Q1out[:max_age, i] + dQ1outu[:max_age]
            theta1[1:i+2, i+1] = np.where(J[i::-1]>0, Q1out[1:i+2, i+1] / J[i::-1], 0.)
            thetaS[1:i+2, i+1] = np.where(J[i::-1]>0, (ST[1:i+2, i+1] - ST[:i+1, i+1]) / J[i::-1], 0.)
            MassBalance[1:i+2, i+1] = np.diff(ST[:i+2, i+1]) - dt * (J[i::-1] - Q1out[1:i+2, i+1])
            MassBalance[i+2:max_age+1, i+1] = np.diff(ST[i+1:max_age+1, i+1]) - dt * (np.diff(ST_init[:max_age-i]) - Q1out[i+2:max_age+1, i+1])
        if np.mod(i+1,1000)==0:
            _verbose('...done ' + str(i+1) + ' of ' + str(max_age) + ' in ' + str(time.clock() - start_time) + ' seconds')
    # Done. Return the outputs
    if full_outputs and C_in is not None:
        return C_out, ST, PQ1, Q1out, theta1, thetaS, MassBalance
    elif full_outputs and C_in is None:
        return ST, PQ1, Q1out, theta1, thetaS, MassBalance
    elif not full_outputs and C_in is not None:
        return C_out
