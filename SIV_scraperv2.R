if (!require("pacman")) install.packages("pacman")
library(pacman)
pacman::p_load(zoo, dplyr, readxl, xml2, XML, purrr, readr, stringr, reshape2, 
               data.table, pdftools, shiny, writexl, DT, tidyr, tibble, tabulizer, rvest, pdftools, shinythemes)

#Download web page 
filePath="https://ec.europa.eu/info/food-farming-fisheries/farming/facts-and-figures/markets/overviews/market-observatories/fruit-and-vegetables/fruit-and-vegetables-various-statistics_en"
download.file(filePath, destfile = "Data/temp_files/scrapedpage.html", quiet=TRUE)

ui <- fluidPage(theme = shinytheme("cosmo"),
                
      # Sidebar layout with a input and output definitions ----
      navbarPage("SIV scraper",
                 tabPanel("SIV data",
                          # Output: Verbatim text for data summary ----
                          hr(),
                          actionButton("submitSIV", "Submit"),
                          downloadButton("dl_SIV", "Download"),
                          hr(),
                          DTOutput("SIV_view"))
                 )#end of navbar page
      )#end of UI

server <- function(input, output, session) {

  ##Get address of PDF file  
  address=function(){
    page <- read_html("Data/temp_files/scrapedpage.html")
    page %>%
      html_nodes("a") %>%       # find all links
      html_attr("href") %>%     # get the url
      str_subset("\\.pdf") %>% # find those that end in pdf
      .[[5]]                    # look at the fifth one
  }

  SIV_data=reactiveFileReader(
    intervalMillis=86400000,
    session=session,
    filePath=address(),
    readFunc = function(filePath) {
       download.file(filePath, destfile="Data/temp_files/SIV.pdf", mode="wb")
      data <- pdf_data("Data/temp_files/SIV.pdf")[[1]]
      data
    })

  ##Find and clean data date
  SIV_date = reactive({
  SIV_date_row <- SIV_data()[grep("Date:", SIV_data()$text),4]
  SIV_data_date <- SIV_data() %>% filter(y == as.numeric(SIV_date_row))
  SIV_data_date$text <- as.Date(SIV_data_date$text, format = "%d/%m/%Y") 
  SIV_data_date <- SIV_data_date %>% na.omit() %>% dplyr::pull(text) 
  })
  
  SIV_data_clean = reactive({
  #Remove meta data rows
  meta_row <- SIV_data()[grep("Product", SIV_data()$text), 4]
  daily_data <- SIV_data() %>% filter(y >= as.numeric(meta_row))
  
  ##Clean data
  find_cols <- daily_data %>% filter(text %in% c("Product", "Designation", "Origin", "Country", "Market", "Value", "Quantity"))  
  find_cols <- find_cols$x - c(1,13,8,36, 21, 1, 1) 
  find_rows <- unique(daily_data$y)
  find_rows <- find_rows[-1]
  find_start <- min(daily_data$x)-1
  
  ##Turn into table
  clean_data <-  daily_data %>% mutate(col = cut(x, breaks = c(0, find_cols, Inf))) %>% 
    mutate(row = cut(y, breaks = c(0, find_rows, Inf))) %>%
    filter(col != "(0,39]") %>%
    filter(col != "(39,92]") %>%
    arrange(col, row) %>% 
    group_by(col, row) %>% 
    mutate(text = paste(text, collapse = " ")) %>% 
    ungroup() %>%
    select(row, text, col) %>% 
    unique() %>% 
    spread(col, text) %>%
    select(-row)
  
  #Change col names
  colnames(clean_data) <- clean_data[1,]
  clean_data <- clean_data[-1,]
   clean_data <- clean_data[which(!is.na(colnames(clean_data)))]
   clean_data <- clean_data %>% select(Designation, `Origin Code`, Country, `Market Place`, Value, Quantity)
   
  ##Fill down data
  clean_data <- fill(clean_data, 1:3)

  ##Clean lemon data
  clean_data$Designation <- gsub("limonum)", "Lemons", clean_data$Designation)
  clean_data <- clean_data %>%
    na.omit() %>%
     mutate(Date = as.Date(SIV_date(), format = "%Y-%m-%d"))
  })

  ##Scrape in currency data
  currency_conversion = reactive({
  fileURL <- "https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/gbp.xml"
  download.file(fileURL, destfile=tf <- tempfile(fileext=".xml"))

  xml_file <- xmlParse(tf)
  xml_data <- xmlRoot(xml_file)

  m <- t(xpathSApply(xml_data, "//*[@OBS_VALUE]", xmlAttrs))
  currency <- as_tibble(read.table(text = paste(m[, 1], m[, 2]), as.is = TRUE))
  colnames(currency) <- c("Date", "euro_to_pound")
  currency$Date <- as.Date(currency$Date)
  currency <- currency %>% filter(Date > "2020-01-01")
  })
  
  ##Join data and currency conversion and calculate prices
  SIV_daily_prices = reactive({
  full_table <- left_join(SIV_data_clean(), currency_conversion())
  full_table$Value <- as.numeric(full_table$Value)
  full_table$Quantity <- as.numeric(full_table$Quantity)
  full_table <- full_table %>% mutate("Price" = (Value*euro_to_pound)) 
  })
  
  ##Read in backseries
  backseries = reactive({
    readRDS("Data/backseries.RDS")
  })
  
  ##Full series to save, avoiding duplication
  full_series = reactive({
    if(sum(grepl(SIV_date(), backseries()$Date)) != 0){
      backseries()}
    else{
      bind_rows(backseries(), SIV_daily_prices()) %>% arrange(Date, Designation) 
    }
  })
  
  weekly_series = reactive({
      full_series() %>% mutate(Date = strftime(Date, format = "%Y-%V")) %>% 
      group_by(Designation, Country, Date) %>% 
      summarise(Price = weighted.mean(Price, Quantity, na.rm = T), 
                Quantity = sum(Quantity, na.rm = T))
  })
  
  ##Save data on button press
  observeEvent(input$submitSIV, {
    saveRDS(full_series(),file = "Data/backseries.RDS")
    saveRDS(weekly_series(),file = "Data/weeklyseries.RDS")
  })
  
  ##Popup window on data save
  observeEvent(input$submitSIV, {
    showModal(modalDialog(
      title = "Data saved to app!",
      "To download this data instead please select download"
    ))
  })
  
  ##Download file to local computer
  
  #Download data to local computer
  output$dl_SIV <- downloadHandler(
    filename = function() { "SIV_backseries.xlsx"},
    content = function(file) {write_xlsx(list("raw_data" = full_series()), path = file)}
  )
  
  ##Data table
  output$SIV_view <- renderDT({
    dataset <- SIV_data_clean()   
    datatable(dataset, rownames = F,
              options = list(
                scrollX = TRUE,
                scrollY = TRUE,
                pageLength = 25,
                order = list(list(6, 'desc')),
                dom = 'Blrtip'
              ))
  })
}


# Run the app ----
shinyApp(ui, server)



