  !                                                                            
  ! Copyright (C) 2010-2016 Samuel Ponce', Roxana Margine, Carla Verdi, Feliciano Giustino 
  ! Copyright (C) 2007-2009 Jesse Noffsinger, Brad Malone, Feliciano Giustino  
  !                                                                            
  ! This file is distributed under the terms of the GNU General Public         
  ! License. See the file `LICENSE' in the root directory of the               
  ! present distribution, or http://www.gnu.org/copyleft.gpl.txt .             
  !                                                                            
  !--------------------------------------------------------
  SUBROUTINE ktokpmq(xk, xq, sign, ipool, nkq, nkq_abs)
  !--------------------------------------------------------
  !!
  !!   For a given k point in cart coord, find the index 
  !!   of the corresponding (k + sign*q) point
  !!
  !!   In the parallel case, determine also the pool number
  !!   nkq is the in-pool index, nkq_abs is the absolute
  !!   index
  !!
  !--------------------------------------------------------
  !
  USE kinds,          only : DP
  use pwcom,          ONLY : nkstot
  USE cell_base,      ONLY : at
  USE start_k,        ONLY : nk1, nk2, nk3
  use klist_epw,      ONLY : xk_cryst
  USE mp_global,      ONLY : nproc_pool, npool
  USE mp_images,      ONLY : nproc_image
  USE mp,             ONLY : mp_barrier, mp_bcast
  USE constants_epw,  ONLY : eps5
  !
  IMPLICIT NONE
  !
  INTEGER, INTENT(in) :: sign
  !! +1 for searching k+q, -1 for k-q
  INTEGER, INTENT(out) :: nkq
  !! The pool hosting the k+-q point    
  INTEGER, INTENT(out) :: nkq_abs
  !! the index of k+sign*q
  INTEGER, INTENT(out) :: ipool
  !! The pool hosting the k+sign*q point
  REAL(KIND = DP), INTENT(in) :: xk(3)
  !! coordinates of k points
  REAL(KIND = DP), INTENT(in) :: xq(3)
  !! Coordinates of q point
  !
  ! work variables
  !
  INTEGER :: ik
  !! Counter on k-points
  INTEGER :: n
  !! Mapping index of k+q on k
  INTEGER :: iks, nkl, nkr, jpool, kunit
  !
  REAL(KIND = DP) :: xxk(3)
  !! Coords. of k-point
  REAL(KIND = DP) :: xxq(3)
  !! Coords. of q-point
  REAL(KIND = DP) :: xx, yy, zz
  !! current k and k+q points in crystal coords. in multiple of nk1, nk2, nk3
  REAL(KIND = DP) :: xx_c, yy_c, zz_c
  !! k-points in crystal coords. in multiple of nk1, nk2, nk3
  !
  LOGICAL :: in_the_list, found
  !
  IF (ABS(sign)/=1) call errore('ktokpmq','sign must be +1 or -1',1)
  !
  ! bring k and q in crystal coordinates
  !
  xxk = xk
  xxq = xq
  !
  CALL cryst_to_cart(1, xxk, at, -1)
  CALL cryst_to_cart(1, xxq, at, -1)
  !
  !  check that k is actually on a uniform mesh centered at gamma
  !
  xx = xxk(1) * nk1
  yy = xxk(2) * nk2
  zz = xxk(3) * nk3
  in_the_list = ABS(xx-NINT(xx)) <= eps5 .AND. &
                ABS(yy-NINT(yy)) <= eps5 .AND. &
                ABS(zz-NINT(zz)) <= eps5
  IF (.NOT. in_the_list) CALL errore('ktokpmq','is this a uniform k-mesh?',1)
  !
  IF (xx < -eps5 .OR. yy < -eps5 .OR. zz < -eps5 ) &
     CALL errore('ktokpmq','coarse k-mesh needs to be strictly positive in 1st BZ',1)
  !
  !  now add the phonon wavevector and check that k+q falls again on the k grid
  !
  xxk = xxk + DBLE(sign) * xxq
  !
  xx = xxk(1) * nk1
  yy = xxk(2) * nk2
  zz = xxk(3) * nk3
  in_the_list = ABS(xx-NINT(xx)) <= eps5 .AND. &
                ABS(yy-NINT(yy)) <= eps5 .AND. &
                ABS(zz-NINT(zz)) <= eps5
  IF (.NOT. in_the_list) CALL errore('ktokpmq','k+q does not fall on k-grid',1)
  !
  !  find the index of this k+q in the k-grid
  !
  !  make sure xx, yy and zz are in 1st BZ
  !
  CALL backtoBZ( xx, yy, zz, nk1, nk2, nk3 )
  !
  n = 0
  found = .false.
  DO ik = 1, nkstot
     xx_c = xk_cryst(1, ik) * nk1
     yy_c = xk_cryst(2, ik) * nk2
     zz_c = xk_cryst(3, ik) * nk3
     !
     ! check that the k-mesh was defined in the positive region of 1st BZ
     !
     IF (xx_c < -eps5 .OR. yy_c < -eps5 .OR. zz_c < -eps5 ) &
        CALL errore('ktokpmq','coarse k-mesh needs to be strictly positive in 1st BZ',1)
     !
     found = NINT(xx_c) == NINT(xx) .AND. &
             NINT(yy_c) == NINT(yy) .AND. &
             NINT(zz_c) == NINT(zz)
     IF (found) THEN  
        n = ik
        EXIT
     ENDIF
  ENDDO
  !
  !  26/06/2012 RM
  !  since coarse k- and q- meshes are commensurate, one can easily find n
  !  n = NINT(xx) * nk2 * nk3 + NINT(yy) * nk3 + NINT(zz) + 1
  !
  IF (n == 0) call errore('ktokpmq','problem indexing k+q',1)
  !
  !  Now n represents the index of k+sign*q in the original k grid.
  !  In the parallel case we have to find the corresponding pool 
  !  and index in the pool
  !
#if defined(__MPI)
  !
  npool = nproc_image / nproc_pool
  kunit = 1
  !
  DO jpool = 0, npool-1
    !
    nkl = kunit * ( nkstot / npool )
    nkr = ( nkstot - nkl * npool ) / kunit
    !
    !  the reminder goes to the first nkr pools (0...nkr-1)
    !
    IF (jpool < nkr ) nkl = nkl + kunit
    !
    !  the index of the first k point in this pool
    !
    iks = nkl * jpool + 1
    IF (jpool >= nkr ) iks = iks + nkr * kunit
    !
    IF (n >= iks) THEN
      ipool = jpool + 1
      nkq = n - iks + 1
    ENDIF
    !
  ENDDO
  !
#else
  !
  ipool = 1
  nkq = n
  !
#endif
  !
  nkq_abs = n
  !
  !--------------------------------------------------------
  END SUBROUTINE ktokpmq
  !--------------------------------------------------------
    IF (NINT(yy) < ib * n2) yy = yy + (-ib + 1) * n2
    IF (NINT(zz) < ib * n3) zz = zz + (-ib + 1) * n3
  ENDDO
  DO ib = 2, 1, -1
    IF (NINT(xx) >= ib * n1) xx = xx - ib * n1
    IF (NINT(yy) >= ib * n2) yy = yy - ib * n2
    IF (NINT(zz) >= ib * n3) zz = zz - ib * n3
  ENDDO
  !
  !-------------------------------------------
  END SUBROUTINE backtoBZ
  !-------------------------------------------

