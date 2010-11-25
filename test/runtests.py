import sys, os
import optparse
import unittest

def getoptionparser():
    parser = optparse.OptionParser()

    parser.add_option("-q", "--quiet",
                      action="store_const", const=0, dest="verbose", default=1,
                      help="do not print status messages to stdout")
    parser.add_option("-v", "--verbose",
                      action="store_const", const=2, dest="verbose", default=1,
                      help="print status messages to stdout")
    parser.add_option("-i", "--include", type="string",
                      action="append",  dest="include", default=[],
                      help="include tests matching PATTERN", metavar="PATTERN")
    parser.add_option("-e", "--exclude", type="string",
                      action="append", dest="exclude", default=[],
                      help="exclude tests matching PATTERN", metavar="PATTERN")
    parser.add_option("--path", type="string",
                      action="append", dest="path", default=[],
                      help="prepend PATH to sys.path", metavar="PATH")
    parser.add_option("--refleaks", type="int",
                      action="store", dest="repeats", default=3,
                      help="run tests REPEAT times in a loop to catch leaks",
                      metavar="REPEAT")
    parser.add_option("--no-threads",
                      action="store_false", dest="threaded", default=True,
                      help="initialize MPI without thread support")
    parser.add_option("--thread-level", type="choice",
                      choices=["single", "funneled", "serialized", "multiple"],
                      action="store", dest="thread_level", default="multiple",
                      help="initialize MPI with required thread support")
    parser.add_option("--mpe",
                      action="store_true", dest="mpe", default=False,
                      help="use MPE for MPI profiling")
    return parser

def getbuilddir():
    from distutils.util import get_platform
    s = os.path.join("build", "lib.%s-%.3s" % (get_platform(), sys.version))
    if (sys.version[:3] >= '2.6' and
        hasattr(sys, 'gettotalrefcount')):
        s += '-pydebug'
    return s

def setup_python(options):
    rootdir = os.path.dirname(os.path.dirname(__file__))
    builddir = os.path.join(rootdir, getbuilddir())
    if os.path.exists(builddir):
        sys.path.insert(0, builddir)
    if options.path:
        path = options.path[:]
        path.reverse()
        for p in path:
            sys.path.insert(0, p)

def setup_unittest(options):
    from unittest import TestSuite
    try:
        from unittest.runner import _WritelnDecorator
    except ImportError:
        from unittest import _WritelnDecorator
    #
    if sys.version[:3] < '2.4':
        TestSuite.__iter__ = lambda self: iter(self._tests)
    #
    writeln_orig = _WritelnDecorator.writeln
    def writeln(self, message=''):
        try: self.stream.flush()
        except: pass
        writeln_orig(self, message)
        try: self.stream.flush()
        except: pass
    _WritelnDecorator.writeln = writeln

def import_package(options, pkgname):
    package = __import__(pkgname)
    #
    import mpi4py.rc
    mpi4py.rc.threaded = options.threaded
    mpi4py.rc.thread_level = options.thread_level
    if options.mpe:
        mpi4py.rc.profile('MPE', logfile='runtests-mpi4py')
    import mpi4py.MPI
    #
    return package

def getprocessorinfo():
    from mpi4py import MPI
    rank = MPI.COMM_WORLD.Get_rank()
    name = MPI.Get_processor_name()
    return (rank, name)

def writeln(message='', endl='\n'):
    sys.stderr.flush()
    sys.stderr.write(message+endl)
    sys.stderr.flush()

def print_banner(options, package):
    rank, name = getprocessorinfo()
    x, y = sys.version_info[:2]
    if options.verbose:
        writeln("[%d@%s] Py%d%d (%s) - %s (%s)"
                % (rank, name, x, y,
                   sys.executable,
                   package.__name__,
                   package.__path__[0]))

def load_tests(options, args):
    from glob import glob
    testsuitedir = os.path.dirname(__file__)
    sys.path.insert(0, testsuitedir)
    pattern = 'test_*.py'
    wildcard = os.path.join(testsuitedir, pattern)
    testfiles = glob(wildcard)
    testfiles.sort()
    testsuite = unittest.TestSuite()
    for testfile in testfiles:
        filename = os.path.basename(testfile)
        modname = os.path.splitext(filename)[0]
        testname = modname.replace('test_','')
        if (modname in options.exclude or
            testname in options.exclude):
            continue
        if (options.include and
            not (modname  in options.include or
                 testname in options.include)):
            continue
        module = __import__(modname)
        loader = unittest.TestLoader()
        for arg in args:
            try:
                cases = loader.loadTestsFromNames((arg,), module)
                testsuite.addTests(cases)
            except AttributeError:
                pass
        if not args:
            cases = loader.loadTestsFromModule(module)
            testsuite.addTests(cases)
    return testsuite

def run_tests(options, testsuite):
    runner = unittest.TextTestRunner(verbosity=options.verbose)
    result = runner.run(testsuite)
    return result.wasSuccessful()

def run_tests_leaks(options, testsuite):
    from sys import gettotalrefcount
    from gc import collect
    rank, name = getprocessorinfo()
    r1 = r2 = 0
    repeats = options.repeats
    while repeats:
        repeats -= 1
        collect()
        r1 = gettotalrefcount()
        run_tests(options, testsuite)
        collect()
        r2 = gettotalrefcount()
        writeln('[%d@%s] refleaks:  (%d - %d) --> %d'
                % (rank, name, r2, r1, r2-r1))

def main(pkgname):
    parser = getoptionparser()
    (options, args) = parser.parse_args()
    setup_python(options)
    setup_unittest(options)
    package = import_package(options, pkgname)
    print_banner(options, package)
    testsuite = load_tests(options, args)
    success = run_tests(options, testsuite)
    if hasattr(sys, 'gettotalrefcount'):
        run_tests_leaks(options, testsuite)
    sys.exit(not success)

if __name__ == '__main__':
    main('mpi4py')