-- Launch browser on a free localhost port
ProgramAddr('127.0.0.1')
ProgramPort(0)
ProgramCache(365 * 24 * 60 * 60, '')

g_DbPath = arg[1]

LaunchBrowser()