from travel import travel_minutes

home = (33.772131075703705, -84.39184878989136)   
venue = (33.777169063407804, -84.39585433230826) 

for mode in ["driving-traffic", "walking", "cycling"]:
    mins, source = travel_minutes(home, venue, mode)
    print(f"{mode:16} {mins:5.1f} min  ({source})")