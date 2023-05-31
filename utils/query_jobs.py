import query
#tables = query.do_query("\dt")
#print(tables)

"""
QUEUED = 10
RUNNING = 20
FAILED = 30
COMPLETED = 40
CANCELED = 50
"""

#output = query.do_query(f"select * from app_task where status<30") #.split('\n')
output = query.do_query(f"select id,project_id,name from app_task where status<30") #.split('\n')
print(output)

