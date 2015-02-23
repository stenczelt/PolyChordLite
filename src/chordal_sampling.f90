module chordal_module
    implicit none

    contains

    function SliceSampling(loglikelihood,priors,settings,logL,seed_point,cholesky,nlike)  result(baby_points)
        use priors_module, only: prior
        use settings_module, only: program_settings
        use random_module, only: random_orthonormal_basis,random_real
        use utils_module, only: logzero,FLT_FMT,fmt_len,stdout_unit,heisenbug_fb,stdout_unit

        implicit none
        interface
            function loglikelihood(theta,phi,context)
                double precision, intent(in),  dimension(:) :: theta
                double precision, intent(out),  dimension(:) :: phi
                integer,          intent(in)                 :: context
                double precision :: loglikelihood
            end function
        end interface

        ! ------- Inputs -------
        !> The prior information
        type(prior), dimension(:), intent(in) :: priors

        !> program settings (mostly useful to pass on the number of live points)
        type(program_settings), intent(in) :: settings

        !> The seed point
        double precision, intent(in), dimension(settings%nTotal)   :: seed_point

        !> The loglikelihood contour to sample on
        double precision, intent(in)   :: logL

        !> The directions of the chords
        double precision, intent(in), dimension(settings%nDims,settings%nDims) :: cholesky

        ! ------- Outputs -------
        !> The number of likelihood evaluations
        integer, intent(out) :: nlike

        !> The newly generated point, plus the loglikelihood bound that
        !! generated it
        double precision,    dimension(settings%nTotal,settings%num_babies)   :: baby_points


        ! ------- Local Variables -------
        double precision,    dimension(settings%nDims)   :: nhat
        double precision,    dimension(settings%nDims,settings%num_babies)   :: nhats

        double precision, dimension(settings%nTotal)   :: previous_point

        integer :: i_babies

        double precision,dimension(settings%grades%min_grade:settings%grades%max_grade) :: timers
        double precision :: time0,time1
        integer, dimension(settings%num_babies) :: grade_order

        logical do_timing

        double precision :: w

        character(len=fmt_len) :: fmt_1

        if(settings%feedback>=heisenbug_fb) write(stdout_unit,'("Slicing")')


        ! Start the baby point at the seed point
        previous_point = seed_point

        ! Initialise the likelihood counter at 0
        nlike = 0

        if(settings%do_timing) then
            do_timing = random_real()<1d0/settings%print_timing
        else
            do_timing=.false.
        end if

        ! Generate a choice of nhats in the orthogonalised space
        if(settings%do_grades) then
            nhats = generate_nhats(settings,grade_order)
            if(do_timing) timers=0
        else
            nhats = generate_nhats(settings)
        end if

        ! Transform to the unit hypercube
        nhats = matmul(cholesky,nhats)



        do i_babies=1,settings%num_babies
            ! Zero the timer
            if(do_timing) call cpu_time(time0)

            ! Get a new random direction
            nhat = nhats(:,i_babies)

            ! Normalise it
            w = sqrt(dot_product(nhat,nhat))
            nhat = nhat/w
            w = w * 1d0 !* exp( lgamma(0.5d0 * settings%nDims) - lgamma(1.5d0 + 0.5d0 * settings%nDims) ) * settings%nDims

            ! Generate a new random point along the chord defined by the previous point and nhat
            baby_points(:,i_babies) = slice_sample(loglikelihood,priors,logL, nhat, previous_point, w, settings,nlike)

            if(baby_points(settings%l0,i_babies)<=logzero) then
                baby_points(settings%l0,settings%num_babies)=logzero
                return
            end if

            ! Save this for the next loop
            previous_point = baby_points(:,i_babies)

            ! Note the time for this grade
            if(do_timing) then
                call cpu_time(time1)
                if(settings%do_grades) timers(grade_order(i_babies)) = timers(grade_order(i_babies)) + time1-time0
            end if
        end do

        if(do_timing.and.settings%do_grades) then 
            write(fmt_1,'("(",I0,"(",A,",""% ""), ""(Total time:"",",A,",""seconds)"")")') &
                settings%grades%max_grade-settings%grades%min_grade+1, FLT_FMT,FLT_FMT
            write(stdout_unit,fmt_1) timers/sum(timers)*100, sum(timers)
        end if


    end function SliceSampling

    function generate_nhats(settings,grade_order) result(nhats)
        use settings_module, only: program_settings
        use random_module, only: random_orthonormal_basis,shuffle_deck
        implicit none
        type(program_settings), intent(in) :: settings

        integer, dimension(settings%num_babies), intent(out),optional :: grade_order

        double precision,    dimension(settings%nDims,settings%num_babies)   :: nhats


        integer :: i_grade
        integer :: grade_nDims
        integer :: grade_index
        integer :: num_repeats
        integer :: i_repeat

        integer :: i_babies

        integer, dimension(settings%num_babies) :: deck

        ! Initialise at 0
        nhats=0d0

        i_babies=1
        if(present(grade_order)) then

            ! Generate a sequence of random bases
            do i_grade=settings%grades%min_grade,settings%grades%max_grade

                grade_nDims = settings%grades%grade_nDims(i_grade)
                grade_index = settings%grades%grade_index(i_grade) 
                num_repeats = settings%grades%num_repeats(i_grade) 

                do i_repeat=1, num_repeats
                    nhats(grade_index:grade_index+grade_nDims-1,i_babies:i_babies+grade_nDims-1) = &
                        random_orthonormal_basis(grade_nDims)
                    grade_order(i_babies:i_babies+grade_nDims-1)=i_grade
                    i_babies = i_babies + grade_nDims
                end do

            end do
        else
            ! Generate a sequence of random bases
            do i_repeat=1, settings%num_repeats
                nhats(:,i_babies:i_babies+settings%nDims-1) = random_orthonormal_basis(settings%nDims)
                i_babies = i_babies + settings%nDims
            end do
        end if

        ! Create a shuffled deck
        deck = (/ (i_babies,i_babies=1,settings%num_babies) /)
        call shuffle_deck(deck(2:settings%num_babies))

        ! Shuffle the nhats
        nhats = nhats(:,deck)

        ! Shuffle the grade order
        if(present(grade_order)) grade_order = grade_order(deck)


    end function generate_nhats






    !> Slice sample at slice logL, along the direction defined by nhat, starting at x0.
    !!
    !! We loosely follow the notation found in Neal's landmark paper:
    !! [Neal 2003](http://projecteuclid.org/download/pdf_1/euclid.aos/1056562461).
    !!
    !! We use the 'stepping out proceedure' to expand the bounds R and L until
    !! they lie outside the iso-likelihood contour, and then contract inwards
    !! using the  'shrinkage' procedure
    !!
    !! Each seed point x0 contains an initial estimate of the width w.
    !!
    function slice_sample(loglikelihood,priors,logL,nhat,x0,w,S,n) result(baby_point)
        use settings_module, only: program_settings
        use priors_module, only: prior
        use utils_module,  only: logzero, distance
        use random_module, only: random_real
        use calculate_module, only: calculate_point
        implicit none
        interface
            function loglikelihood(theta,phi,context)
                double precision, intent(in),  dimension(:) :: theta
                double precision, intent(out),  dimension(:) :: phi
                integer,          intent(in)                 :: context
                double precision :: loglikelihood
            end function
        end interface

        !> The prior information
        type(prior), dimension(:), intent(in) :: priors
        !> program settings
        type(program_settings), intent(in) :: S
        !> The Loglikelihood bound
        double precision, intent(in)                           :: logL
        !> The direction to search for the root in
        double precision, intent(in),    dimension(S%nDims)   :: nhat
        !> The start point
        double precision, intent(in),    dimension(S%nTotal)   :: x0
        !> The initial width
        double precision, intent(in) :: w
        !> The number of likelihood calls
        integer, intent(inout) :: n

        ! The output finish point
        double precision,    dimension(S%nTotal)   :: baby_point

        ! The upper bound
        double precision,    dimension(S%nTotal)   :: R
        ! The lower bound
        double precision,    dimension(S%nTotal)   :: L


        double precision :: temp_random

        integer :: i_step

        ! Select initial start and end points
        temp_random = random_real()
        L(S%h0:S%h1) = x0(S%h0:S%h1) -   temp_random   * w * nhat 
        R(S%h0:S%h1) = x0(S%h0:S%h1) + (1-temp_random) * w * nhat 

        ! Calculate initial likelihoods
        call calculate_point(loglikelihood,priors,R,S,n)
        call calculate_point(loglikelihood,priors,L,S,n)

        ! expand R until it's outside the likelihood region
        i_step=0
        do while( R(S%l0) >= logL .and. R(S%l0) > logzero )
            i_step=i_step+1
            R(S%h0:S%h1) = x0(S%h0:S%h1) + nhat * w * i_step
            call calculate_point(loglikelihood,priors,R,S,n)
            n=n+1
        end do
        if(i_step>100) write(*,'(" too many R steps (",I10,")")') i_step

        ! expand L until it's outside the likelihood region
        i_step=0
        do while(L(S%l0) >= logL      .and. L(S%l0) > logzero )
            i_step=i_step+1
            L(S%h0:S%h1) = x0(S%h0:S%h1) - nhat * w * i_step
            call calculate_point(loglikelihood,priors,L,S,n)
        end do
        if(i_step>100) write(*,'(" too many L steps (",I10,")")') i_step

        ! Sample within this bound
        i_step=0
        baby_point = find_positive_within(L,R)

        contains

        recursive function find_positive_within(L,R) result(x1)
            implicit none
            !> The upper bound
            double precision, intent(inout), dimension(S%nTotal)   :: R
            !> The lower bound
            double precision, intent(inout), dimension(S%nTotal)   :: L

            ! The output finish point
            double precision,    dimension(S%nTotal)   :: x1

            double precision :: x0Rd
            double precision :: x0Ld

            i_step=i_step+1
            if (i_step>1000) then
                write(*,*) 'Polychord Warning: Non deterministic loglikelihood'
            end if

            ! Find the distance between x0 and L 
            x0Ld= distance(x0(S%h0:S%h1),L(S%h0:S%h1))
            ! Find the distance between x0 and R 
            x0Rd= distance(x0(S%h0:S%h1),R(S%h0:S%h1))

            ! Draw a random point within L and R
            x1(S%h0:S%h1) = x0(S%h0:S%h1)+ (random_real() * (x0Rd+x0Ld) - x0Ld) * nhat 

            ! calculate the likelihood 
            call calculate_point(loglikelihood,priors,x1,S,n)

            ! If we're not within the likelihood bound then we need to sample further
            if( x1(S%l0) < logL .or. x1(S%l0) <= logzero ) then

                if ( dot_product(x1(S%h0:S%h1)-x0(S%h0:S%h1),nhat) > 0d0 ) then
                    ! If x1 is on the R side of x0, then
                    ! contract R
                    R = x1
                else
                    ! If x1 is on the L side of x0, then
                    ! contract L
                    L = x1
                end if

                ! Call the function again
                x1 = find_positive_within(L,R)

            end if
            ! otherwise x1 is returned

        end function find_positive_within


    end function slice_sample


end module chordal_module

