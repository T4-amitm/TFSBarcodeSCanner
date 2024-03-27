//
//  ViewController.swift
//  TFSBarcodeScanner
//
//  Created by T4-amitm on 03/27/2024.
//  Copyright (c) 2024 T4-amitm. All rights reserved.
//

import UIKit
import TFSBarcodeScanner

class ViewController: UIViewController {
    @IBOutlet var previewView: UIView!
    var scanner: TFSBarcodeScanner?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        scanner = TFSBarcodeScanner(previewView: previewView)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        ScannerUtils.requestCameraPermissionWithSuccess { success in
            if success {
                do {
                    var error: NSError? = NSError()
                    // Start scanning with the front camera
                    if let scanStart = self.scanner?.startScanningWithCamera(camera: .front, resultBlock: { codes in
                        if let codes = codes {
                            for code in codes {
                                let stringValue = code.stringValue!
                                print("Found code: \(stringValue)")
                            }
                        }
                    }, error: &error) {
                        if !scanStart {
                        NSLog("Unable to start scanning")
                    }
                }
                  
                } catch {
                    NSLog("Unable to start scanning")
                }
            } else {
                let alertController = UIAlertController(title: "Scanning Unavailable", message: "This app does not have permission to access the camera", preferredStyle: .alert)
                alertController.addAction(UIAlertAction(title: "Ok", style: .default, handler: nil))
                self.present(alertController, animated: true, completion: nil)
            }
        }
    }
    
    
    override func viewWillDisappear(_ animated: Bool) {
        self.scanner?.stopScanning()
        
        super.viewWillDisappear(animated)
    }
    
    @IBAction func switchCameraTapped(sender: UIButton) {
        self.scanner?.flipCamera()
    }
}


