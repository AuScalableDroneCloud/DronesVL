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

#task = "82384388-09f7-4266-a125-f597ede0e7b7"
#task = "c4e5fc7a-7d4f-44fe-9281-7cb0ce635d32"
#task = "3e343f8f-1073-4754-b86c-c7fd4e40e5d8"

#output = query.do_query(f"select uuid,project_id,name,status,options,pending_action from app_task where id=\'{task}\'") #.split('\n')
#output = query.do_query(f"select uuid,project_id,name,status,options,pending_action,console_output from app_task") #.split('\n')
#print(output)
output = query.do_query(f"select count(*) app_task") #.split('\n')
print(output)

#Need single quotes
#output = query.do_query(f"select * from app_imageupload where task_id=\'{task}\'") #.split('\n')
#output = query.do_query(f"select count(*) from app_imageupload where task_id=\'{task}\'") #.split('\n')

#output = do_query("select * from app_imageupload")
#output = do_query("select * from app_task")

#for o in output:
#    print(o)
#print(output)

output = query.do_query(f"select length(console_output) from app_task where length(console_output) > 50;") #.split('\n')
print(output)


