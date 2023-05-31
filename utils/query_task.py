import query
#tables = query.do_query("\dt")
#print(tables)

#task = "82384388-09f7-4266-a125-f597ede0e7b7"
#task = "c4e5fc7a-7d4f-44fe-9281-7cb0ce635d32"
#task = "3e343f8f-1073-4754-b86c-c7fd4e40e5d8"
#task = "c4786612-d9f4-4085-9be0-b0e41ab27b15"
#task = "576fa65f-4fa8-4dab-a97b-f941b8560c48"
#task = "3a70f385-6450-4f41-ab95-ed8c59388d65" #DOUBLED IMAGES
#task = "223317cf-43d3-466f-bed4-9c374f9d4c48" #CORRECT IMAGES
#task = "8d9c6aff-f852-40b3-976c-8ffaee0341cf"
#task = "084eca63-5bb6-49a6-8a2c-defa7478ce8d"
task = "3a883130-a294-44f0-9c47-aa861917d6bb"

#output = query.do_query(f"select uuid,project_id,name,status,options,pending_action from app_task where id=\'{task}\'") #.split('\n')
#output = query.do_query(f"select uuid,name,processing_time,status,last_error,options,created_at,pending_action,processing_node_id,project_id,auto_processing_node,orthophoto_extent,available_assets,dsm_extent,dtm_extent,public,id,resize_to,resize_progress,upload_progress,running_progress,import_url,images_count,partial,potree_scene,epsg from app_task where id=\'{task}\'") #.split('\n')
 
output = query.do_query(f"select console_output from app_task where id=\'{task}\'") #.split('\n')

print(output)
exit()

#output = query.do_query(f"select * from app_imageupload where task_id=\'{task}\'") #.split('\n')
#print('---------------------------')
#print(output)
print('---------------------------')
output = query.do_query(f"select count(*) from app_imageupload where task_id=\'{task}\'") #.split('\n')
print(output)
output = query.do_query(f"select * from app_imageupload where task_id=\'{task}\'") #.split('\n')
print(output)

