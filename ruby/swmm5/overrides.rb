# frozen_string_literal: false
# Hand-ported pieces of EPA SWMM 5.2.4 that use C pointer arithmetic the translator does not map:
# odesolve.c (whole file), mempool.c (whole file), and six helpers from swmm5.c / project.c.
# Each keeps the C statement order and floating-point expressions exactly (a port of the Python port's
# overrides.py). Written by Claude (Anthropic) for Robert Dickinson; see ruby/README.md.

module SWMM5
  def sstrncpy(dest, src, n)
    offset = 0
    if n > 0
      while src[offset] != 0
        break if offset == n
        dest[offset] = src[offset]
        offset += 1
      end
    end
    dest[offset] = 0
    c_strlen(dest)
  end

  def sstrcat(dest, src, size)
    offset = c_strlen(dest)
    src_index = 0
    while src[src_index] != 0
      dest[offset] = src[src_index]
      offset += 1
      src_index += 1
      break if offset == size - 1
    end
    dest[offset] = 0
    c_strlen(dest)
  end

  def getAbsolutePath(fname, absPath, size)
    return if fname.nil? || c_strlen(fname) == 0
    if isRelativePath(fname) != 0
      begin
        full = File.realpath(CRT.bytes_of(fname)).b
      rescue SystemCallError
        return
      end
      m = [full.bytesize, absPath.b.bytesize - absPath.o - 1].min
      absPath.b.bytesplice(absPath.o, m + 1, full.byteslice(0, m) + "\0")
    else
      sstrncpy(absPath, fname, c_strlen(fname))
    end
    endOfDir = c_strrchr(absPath, 47)
    endOfDir[1] = 0 unless endOfDir.nil?
  end

  def getTempFileName(fname)
    sstrncpy(fname, lit('swmmXXXXXX'), MAXFNAME)
    c_mkstemp(fname)
    fname
  end

  def project_createMatrix(nrows, ncols)
    return nil if nrows <= 0 || ncols <= 0
    ::Array.new(nrows) { ::Array.new(ncols, 0.0) }   # EPA zeroes only an eighth (lessons/02, defect 5)
  end

  def project_freeMatrix(a)
    nil
  end

  def AllocInit
    Object.new
  end

  def Alloc(n)
    CPtr.buf(n)
  end

  def AllocSetPool(p)
    p
  end

  def AllocReset
    nil
  end

  def AllocFreePool
    nil
  end

  # ------------------------------------------------------------------ odesolve.c (Cash-Karp Runge-Kutta)
  ODE_MAXSTP = 10000
  ODE_TINY = 1.0e-30
  ODE_SAFETY = 0.9
  ODE_PGROW = -0.2
  ODE_PSHRNK = -0.25
  ODE_ERRCON = 1.89e-4
  ODE = { nmax: 0 }

  def odesolve_open(n)
    ODE[:nmax] = 0
    %i[y yscal dydx yerr ytemp ak2 ak3 ak4 ak5 ak6].each { |k| ODE[k] = ::Array.new(n, 0.0) }
    ODE[:nmax] = n
    1
  end

  def odesolve_close
    ODE.clear
    ODE[:nmax] = 0
    nil
  end

  def odesolve_integrate(ystart, n, x1, x2, eps, h1, derivs)
    y = ODE[:y]
    yscal = ODE[:yscal]
    dydx = ODE[:dydx]
    hdid = [0.0]
    hnext = [0.0]
    x = [x1]
    h = h1
    return 1 if ODE[:nmax] < n
    n.times { |i| y[i] = ystart[i] }
    nstp = 1
    while nstp <= ODE_MAXSTP
      derivs.call(x[0], y, dydx)
      n.times { |i| yscal[i] = y[i].abs + (dydx[i] * h).abs + ODE_TINY }
      h = x2 - x[0] if (x[0] + h - x2) * (x[0] + h - x1) > 0.0
      errcode = ode_rkqs(x, n, h, eps, hdid, hnext, derivs)
      break if errcode != 0
      if (x[0] - x2) * (x2 - x1) >= 0.0
        n.times { |i| ystart[i] = y[i] }
        return 0
      end
      return 2 if hnext[0].abs <= 0.0
      h = hnext[0]
      nstp += 1
    end
    3
  end

  def ode_rkqs(x, n, htry, eps, hdid, hnext, derivs)
    y = ODE[:y]
    yerr = ODE[:yerr]
    yscal = ODE[:yscal]
    ytemp = ODE[:ytemp]
    xold = x[0]
    h = htry
    loop do
      ode_rkck(xold, n, h, derivs)
      errmax = 0.0
      n.times do |i|
        err = (yerr[i] / yscal[i]).abs
        errmax = err if err > errmax
      end
      errmax /= eps
      if errmax > 1.0
        htemp = ODE_SAFETY * h * c_pow(errmax, ODE_PSHRNK)
        if h >= 0
          h = htemp > 0.1 * h ? htemp : 0.1 * h
        else
          h = htemp < 0.1 * h ? htemp : 0.1 * h
        end
        xnew = xold + h
        return 2 if xnew == xold
        next
      else
        hnext[0] = errmax > ODE_ERRCON ? ODE_SAFETY * h * c_pow(errmax, ODE_PGROW) : 5.0 * h
        hdid[0] = h
        x[0] += h
        n.times { |i| y[i] = ytemp[i] }
        return 0
      end
    end
  end

  ODE_A2 = 0.2
  ODE_A3 = 0.3
  ODE_A4 = 0.6
  ODE_A5 = 1.0
  ODE_A6 = 0.875
  ODE_B21 = 0.2
  ODE_B31 = 3.0 / 40.0
  ODE_B32 = 9.0 / 40.0
  ODE_B41 = 0.3
  ODE_B42 = -0.9
  ODE_B43 = 1.2
  ODE_B51 = -11.0 / 54.0
  ODE_B52 = 2.5
  ODE_B53 = -70.0 / 27.0
  ODE_B54 = 35.0 / 27.0
  ODE_B61 = 1631.0 / 55296.0
  ODE_B62 = 175.0 / 512.0
  ODE_B63 = 575.0 / 13824.0
  ODE_B64 = 44275.0 / 110592.0
  ODE_B65 = 253.0 / 4096.0
  ODE_C1 = 37.0 / 378.0
  ODE_C3 = 250.0 / 621.0
  ODE_C4 = 125.0 / 594.0
  ODE_C6 = 512.0 / 1771.0
  ODE_DC5 = -277.0 / 14336.0
  ODE_DC1 = ODE_C1 - 2825.0 / 27648.0
  ODE_DC3 = ODE_C3 - 18575.0 / 48384.0
  ODE_DC4 = ODE_C4 - 13525.0 / 55296.0
  ODE_DC6 = ODE_C6 - 0.25

  def ode_rkck(x, n, h, derivs)
    y = ODE[:y]
    dydx = ODE[:dydx]
    ytemp = ODE[:ytemp]
    yerr = ODE[:yerr]
    ak2 = ODE[:ak2]
    ak3 = ODE[:ak3]
    ak4 = ODE[:ak4]
    ak5 = ODE[:ak5]
    ak6 = ODE[:ak6]
    n.times { |i| ytemp[i] = y[i] + ODE_B21 * h * dydx[i] }
    derivs.call(x + ODE_A2 * h, ytemp, ak2)
    n.times { |i| ytemp[i] = y[i] + h * (ODE_B31 * dydx[i] + ODE_B32 * ak2[i]) }
    derivs.call(x + ODE_A3 * h, ytemp, ak3)
    n.times { |i| ytemp[i] = y[i] + h * (ODE_B41 * dydx[i] + ODE_B42 * ak2[i] + ODE_B43 * ak3[i]) }
    derivs.call(x + ODE_A4 * h, ytemp, ak4)
    n.times { |i| ytemp[i] = y[i] + h * (ODE_B51 * dydx[i] + ODE_B52 * ak2[i] + ODE_B53 * ak3[i] + ODE_B54 * ak4[i]) }
    derivs.call(x + ODE_A5 * h, ytemp, ak5)
    n.times { |i| ytemp[i] = y[i] + h * (ODE_B61 * dydx[i] + ODE_B62 * ak2[i] + ODE_B63 * ak3[i] + ODE_B64 * ak4[i] + ODE_B65 * ak5[i]) }
    derivs.call(x + ODE_A6 * h, ytemp, ak6)
    n.times { |i| ytemp[i] = y[i] + h * (ODE_C1 * dydx[i] + ODE_C3 * ak3[i] + ODE_C4 * ak4[i] + ODE_C6 * ak6[i]) }
    n.times { |i| yerr[i] = h * (ODE_DC1 * dydx[i] + ODE_DC3 * ak3[i] + ODE_DC4 * ak4[i] + ODE_DC5 * ak5[i] + ODE_DC6 * ak6[i]) }
  end
end
